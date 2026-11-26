# openalexImportZenodo — suggested approach

**Status:** design proposal, no code yet. **Date:** 2026-11-25.

Second member of the `openalexImport<Source>` family, after openalexImportPolicy. It downloads
Zenodo records (whole communities and/or searches), keeps them up to date without
re-downloading everything, and writes them as an **openalexPro-formatted works corpus**
(parquet), so openalexAPI, openalexSnowball, openalexVectorComp etc. can use them unchanged.

---

## 1. What it has to do

1. **Download** all records of one or more Zenodo **communities**, the results of Zenodo
   **searches** (query string, optionally restricted to communities / resource types), or a
   given list of record IDs / DOIs.
2. **Update** an existing download incrementally: additions, removals **and metadata edits**,
   without fetching everything again.
3. **Map** each deposit to the OpenAlex works schema, keep everything Zenodo has that OpenAlex
   lacks as `zenodo_*` columns, and keep the **related identifiers** as first-class data.

The import is **based on Zenodo only**: no OpenAlex request is made. Linking to and
enriching from OpenAlex is a separate, later step (section 7).

Out of scope for v1: creating OpenAlex collections (stays in zenodo-openalex-collection /
`pro_collection()`), writing to Zenodo, file content extraction (only file *metadata* and an
on-request download, as in openalexImportPolicy).

---

## 2. Position in the ecosystem

| Reused from | What |
|---|---|
| **zenodo-openalex-collection** (`~/GitHub/zenodo-openalex-collection`) | The whole download/update core: `zenodo_get()` (throttle 2.2 s, 429 handling via `x-ratelimit-reset`, token for 100/page), `zenodo_buckets()` / `check_zenodo()` (count per interval, re-download changed intervals), rolling `recheck`, `fetch_zenodo_range()` (bisection under the 10,000-hit cap), atomic replace via `<dir>.tmp`, `zenodo_deposit()` (concept DOI or record DOI). **Copy** this code into the package; zenodo-openalex-collection stays as it is and keeps working on its own. Whether it later switches to depending on this package is a separate decision. |
| **openalexImportPolicy** | Package shape: `fetch → build → corpus`, `<source>_<field>` extra columns, `write_corpus()` with `.part` + replace, DuckDB for mapping. |
| **openalexPro** | Output layout (`query=<name>/` hive partitions, `_dataset.json` marker when that lands); the corpus must read like any openalexPro download. |
| **openalexAPI** | The corpus contract: works files with `id` + `title`/`display_name`, deduplicated on `id_key(id)` (part after the last `/`, uppercased), extra columns served as they are, `cites:` filter reads `referenced_works`. |

Exported functions use the prefix `zenodo_` (as `policy_` in the sibling).

**Licence:** Zenodo metadata is CC0, so — unlike openalexImportPolicy — the built corpus may be
shared. File contents keep their own licences (`license` per record); only metadata goes
into the corpus.

---

## 3. Inputs: sources

Plain R arguments, no config file. As in openalexPro (`pro_fetch()`, `pro_collection()`),
every function takes a **`project_folder`** and a **`name`** (default `"zenodo"`). `name`
identifies one source inside the project folder (sub-folder and partition name); each call
says what it is — exactly one of `community`, `query` or `ids`:

```r
zenodo_fetch(community = "ipbes", project_folder = "proj",   # name = "zenodo"
             interval = "year", recheck_interval = "month", recheck_per_run = 2)
zenodo_fetch(query = "bats AND switzerland", project_folder = "proj", name = "bats_ch",
             communities = c("ipbes", "biosphere"), resource_type = c("publication", "dataset"),
             interval = "all")
zenodo_fetch(ids = c("10.5281/zenodo.3831673", "7654321"), project_folder = "proj",
             name = "assessment_refs")
```

Optional for all: `from`, `to` (Zenodo `created` range), `interval` (week, month, quarter,
year, all; default year), `recheck_interval` + `recheck_per_run` (rolling recheck),
`full = FALSE`. Several sources = several calls (or `lapply()` / a targets pipeline in the
user's project).

The arguments of the first download are stored in `raw/<name>/_state.json`. A later call
for the same `name` with different query arguments stops with an error (use `full = TRUE`
to redefine it), so an update cannot silently mix two queries.
`zenodo_update(project_folder, name)` reruns a source from its stored arguments; with
`name = NULL`, all sources in `project_folder`.

- **Community** → `GET /api/communities/<id>/records?allversions=true` (as now).
- **Search** → `GET /api/records?q=<query> AND created:[from TO to}&allversions=true`,
  communities / type as extra filters. The bucket logic is identical: the `created` window
  is ANDed onto the user query, so counting and bisection work unchanged.
- **IDs** → resolved via `GET /api/records/<recid>` or `q=doi:"…"`; one bucket `ids`.

A search result set is defined *at run time*: records that stop matching (edited, or the
index changed) disappear from their bucket count and are removed like deleted records.
That is the intended semantics; say so in the docs.

---

## 4. Unit of a work: deposit, not version

OpenAlex merges all versions of a Zenodo deposit into one work under the **concept DOI**.
Do the same:

- **Raw store**: every version (`allversions=true`), exactly as now — needed for the
  count check and for version history.
- **Corpus**: **one row per deposit** (concept record), with the metadata of the **newest
  version** (`is_last`), `doi` = concept DOI (or the record DOI for deposits without one —
  `zenodo_deposit()`), plus a `zenodo_versions` list column (recid, doi, version,
  publication_date, created).
- Import option `versions = "all"` (argument of `zenodo_build()`) writes one row per
  version instead (IDs `zenodo:<recid>`), for version-level analysis. Default `"latest"`
  (decided 2026-11-25, Q1).

The same deposit can sit in several sources (two communities, a community and a search).
The corpus is partitioned per source (`query=<name>/`) like openalexPro, so a deposit can
appear in two partitions; openalexAPI deduplicates on `id`. Add `zenodo_sources` (which
sources the deposit was found in) when writing a combined corpus.

---

## 5. Data layout

```
<project_folder>/
  raw/<name>/<bucket>/*.parquet     every version; id columns + `json` (the full hit, verbatim)
  raw/<name>/_state.json            source arguments, last run (UTC), `updated` watermark, recheck position
  raw/<name>/changes.json           last change (as zenodo_changes.json now)
  corpus/query=<name>/data.parquet  dataset 1: the works (deposits), OpenAlex schema + zenodo_* columns
  corpus/_dataset.json                marker (deterministic; see openalexPro discussion)
  links/query=<name>/data.parquet   dataset 2: the links, one row per link (section 9)
  files/<recid>/<key>                 on request only (zenodo_download_files())
```

So the output is **two parquet datasets**: `corpus/` (one row per deposit — what openalexAPI
serves and every openalexPro package reads) and `links/` (one row per link between a
deposit and another output, shaped like OpenAlex's `/links` entity). They join on
`corpus.id = links.origin` or `links.target`. `links/` is deliberately **outside**
`corpus/`: openalexAPI reads every `*.parquet` below the corpus folder, and the link table
is not a works file. The relations are also in the works rows (`zenodo_related` list
column); the link table is the same information flattened, resolved and oriented, so graph
questions ("all datasets that supplement a paper in this community") are a plain DuckDB
query instead of unnesting lists.

**Important change vs. zenodo-openalex-collection:** keep the **full JSON of each hit** in
the raw parquet (`json` VARCHAR), not only the selected columns. Then remapping (new fields,
fixed mapping) never needs a re-download — the expensive part at 30 requests/minute.
An InvenioRDM hit is ~35 kB as JSON (IPBES: ~35 MB; a 250,000-record community ≈ 9 GB
before parquet compression).

**`select`** (argument of `zenodo_fetch()`, default `NULL` = everything): Zenodo ignores
field selection (`fields=` returns the full record, checked 2026-11-26), so `select` does
not make downloads smaller; it only limits what is stored in `json`. It takes top-level or
dotted paths (`"metadata.title"`, `"metadata.related_identifiers"`); the ID columns are
always kept. It is stored in `_state.json`; changing it needs `full = TRUE`, because fields
not stored can only come back by downloading again. `zenodo_build()` treats missing fields
as empty.

---

## 6. Incremental update

Three mechanisms, each catching what the others miss:

| Change | Detected by | Cost |
|---|---|---|
| New / deleted versions | **Interval count check** (existing `check_zenodo()`): 1 count request per interval, re-download intervals whose count changed | ~14 requests (year) per source and run |
| Add + remove cancelling out in one interval | **Rolling recheck** (existing `recheck: per_run`) | `per_run` extra requests |
| **Metadata edits** (title, related identifiers, new community, licence, …) — counts do not change | **`updated` watermark**: `q=updated:[<watermark - 1 day> TO *]` on the same source; upsert the returned hits into their buckets (bucket from `created`) | 1 request + pages of edited records |

The `updated` query is new; verified live on 2026-11-25:
`/api/communities/ipbes/records?allversions=true&q=updated:[2026-10-01 TO *]` → 13 of 1,034
records. Views and downloads do **not** bump `updated` (checked the same day: the five
most-viewed IPBES records, 70,000–360,000 views each and still being viewed, were last
updated in July/August 2024), so popular records are not re-downloaded every run. Still to
verify: that removing a record from a community bumps `updated` (if not, the count check
catches it anyway).

Rules carried over: buckets are replaced atomically (temp folder, then rename); a failed
run leaves the old data and the old watermark; the watermark only advances after a
successful run; a full re-download stays a manual switch (`full = TRUE`).

Update of the corpus after a fetch: **rebuild only the partitions of sources that changed**
(as `update_corpus()` in openalexImportPolicy). Mapping a few thousand records in DuckDB is
seconds; not worth incremental row-level writes.

---

## 7. Identity, and OpenAlex as a separate later step

**The Zenodo deposit and the OpenAlex work are two different things** (decided
2026-11-25). The aim is to bring the Zenodo deposits, with their Zenodo metadata, into the
openalexPro ecosystem — not to produce another copy of OpenAlex works.

- **`id` is always `zenodo:<conceptrecid>`** (pattern of openalexImportPolicy: no `/`,
  unique when uppercased). It never changes between runs.
- **The import uses Zenodo only.** Every field of the corpus comes from Zenodo; fields
  Zenodo does not have (`cited_by_count`, `topics`, institutions, …) stay empty.
- In a corpus that also holds openalexPro downloads, a deposit that OpenAlex also has is
  there **twice on purpose** — once as the deposit (`zenodo:…`), once as the OpenAlex work
  (`W…`).

**Enrichment from OpenAlex — not part of the import.** Can come later, in this package as
a separate function or elsewhere. Notes for then, so the import does not block it:

- Matching by concept DOI, record DOIs, and publisher DOIs from related identifiers
  (`isIdenticalTo` / `isAlternateIdentifier` / `isVersionOf`); Zenodo deposits are mostly in
  OpenAlex's **expansion** corpus; ~1 credit per 200 works (zenodo-openalex-collection).
- Result: `ids.openalex` = `https://openalex.org/W…`; resolve external DOI targets in the
  link table to `W…`; optionally fill fields Zenodo lacks, with an option
  `openalex_overwrites_zenodo = FALSE` (default) deciding fields both have — Zenodo value
  kept unless `TRUE`.
- It reads the import's output and writes a separate result; the import never depends on it.

---

## 8. Field mapping (Zenodo → OpenAlex works)

**Use the new InvenioRDM format** (`Accept: application/vnd.inveniordm.v1+json`; decided
2026-11-25, Q3). The field paths below are written for the old format the
zenodo-openalex-collection code uses; translate them when implementing (e.g.
`creators[].name` → `creators[].person_or_org.name`, `affiliation` → `affiliations[]` with
ROR ID → `authorships[].institutions`, `license` → `rights`, `relation` →
`relation_type.id`). Live check of an IPBES record (old format): top-level `created, modified, updated, id, recid, conceptrecid, doi, conceptdoi,
metadata, links, files, stats, swh, status, revision`.

### 8.1 Mapped to OpenAlex columns

| OpenAlex | Zenodo | Notes |
|---|---|---|
| `id` | `conceptrecid` | `zenodo:<conceptrecid>` |
| `doi` | `conceptdoi` (else `doi`) | as `https://doi.org/…`, lowercased |
| `title`, `display_name` | `metadata.title` | |
| `abstract` | `metadata.description` | HTML → plain text; HTML kept in `zenodo_description_html`. Also build `abstract_inverted_index` so openalexAPI / openalexPro `enrich` treat it like any work |
| `publication_date`, `publication_year` | `metadata.publication_date` | |
| `type` | `metadata.resource_type.type` / `.subtype` | lookup table `inst/extdata/resource_types.csv` (publication/article → article, preprint → preprint, book → book, section → book-chapter, thesis → dissertation, report → report, dataset → dataset, software → check current OpenAlex type list, else other …); originals in `zenodo_resource_type`, `zenodo_resource_subtype` |
| `language` | `metadata.language` (ISO 639-3) | → ISO 639-1 via a table (as `languages.csv` in openalexImportPolicy) |
| `authorships` | `metadata.creators[]` | `author.display_name` = `name`, `author.orcid`, `raw_author_name`, `raw_affiliation_strings` = `affiliation`, `author_position` first/middle/last, `institutions` = [] (no ROR in the old API format; the new format has ROR IDs, see Q3 in section 12) |
| `primary_location` | `links.html`, open PDF in `files`, `metadata.license.id`, `metadata.version` | `source` = OpenAlex's Zenodo repository source (look up its `S…` ID once, do not hard-code from memory), `is_oa` = `access_right == "open"`, `license` normalised to OpenAlex style (`cc-by-4.0` → `cc-by`) |
| `open_access` | `access_right`, `files` | `is_oa`, `oa_status` = `green` if open, `oa_url` |
| `keywords` | `metadata.keywords`, `metadata.subjects` | `{display_name}`; subjects keep their scheme in `zenodo_subjects` |
| `funders` / `awards` (older `grants`) | `metadata.grants[]` | funder from `funder.doi` (Crossref Funder ID) → OpenAlex funder via lookup; award id = `code`; raw in `zenodo_grants` |
| `biblio` | `metadata.journal.{volume,issue,pages}` | `pages` split into first/last page |
| `referenced_works` | `related_identifiers` with relation `cites` / `references`, pointing to deposits in the corpus, as `zenodo:` IDs | section 9 |
| `created_date`, `updated_date` | `created`, `updated` | |
| `ids` | conceptdoi (else doi), conceptrecid | `{doi, zenodo: <conceptrecid>}`; `openalex` only after a later enrichment |

Not filled (Zenodo has no such data): `cited_by_count`, `counts_by_year`, `topics`,
`concepts`, `related_works` (OpenAlex's is algorithmic; do not overload it with Zenodo
relations), `fwci`, `citation_normalized_percentile`.

### 8.2 Extra `zenodo_*` columns

| Column | From | Why |
|---|---|---|
| `zenodo_recid`, `zenodo_conceptrecid`, `zenodo_record_doi`, `zenodo_concept_doi`, `zenodo_version` | top level / metadata | identity, version in hand |
| `zenodo_versions` | all versions of the deposit | list of struct (recid, doi, version, publication_date, created) |
| `zenodo_related` | `metadata.related_identifiers` | **list of struct**, normalised and resolved (section 9) |
| `zenodo_references` | `metadata.references` | free-text reference strings (no IDs); candidates for later matching |
| `zenodo_communities` | `metadata.communities[].id` | community membership — essential for filtering |
| `zenodo_sources` | this package | which sources found the deposit |
| `zenodo_contributors` | `metadata.contributors[]` | name, affiliation, orcid, `type` (Editor, DataCollector, …); not authors |
| `zenodo_files` | `files[]` | key, size, checksum, url; basis for `zenodo_download_files()` |
| `zenodo_access_right`, `zenodo_embargo_date`, `zenodo_license` | metadata | raw access info |
| `zenodo_locations` | `metadata.locations[]` | geo points + place — relevant for biodiversity/IPBES work |
| `zenodo_dates` | `metadata.dates[]` | collected / valid / withdrawn ranges |
| `zenodo_method`, `zenodo_notes` | metadata | |
| `zenodo_imprint`, `zenodo_thesis`, `zenodo_meeting`, `zenodo_part_of` | metadata | host book / thesis / conference info |
| `zenodo_stats` | `stats` | views/downloads as of the record's last download, with `zenodo_stats_date`; only with import option `stats = TRUE` (default `FALSE`; Q2 in section 12) |
| `zenodo_swh` | `swh` | Software Heritage IDs for software deposits |
| `zenodo_status` | `status`, tombstones | published / deleted |

Everything else in the hit is still available via the raw `json`, so a missing field is a
mapping change, not a re-download.

---

## 9. Related identifiers (the important part)

Zenodo `related_identifiers` carry DataCite relations between a deposit and other
outputs: the paper a dataset supplements, the software a paper documents, the chapters
of an assessment, the data a figure is derived from. For IPBES-type communities this is
the most valuable information Zenodo has and OpenAlex mostly lacks. Each entry:
`identifier`, `relation`, `scheme`, `resource_type` (already parsed in `zenodo_records()`).

### 9.1 Storage: column + link table

1. **`zenodo_related`** (list column on the work): everything as declared, normalised, for
   users who look at one work.
2. **`links/`** (a second parquet dataset next to `corpus/`, one row per link), shaped like
   OpenAlex's links entity (`api.openalex.org/links?filter=target:W…` → `origin`, `target`,
   `link_type`), for graph work, joins and snowballing:

| Column | Content |
|---|---|
| `origin`, `target` | `zenodo:<conceptrecid>` for Zenodo deposits, else the normalised identifier (`https://doi.org/…`, URL, …) |
| `link_type` | OpenAlex link-type URL (`https://openalex.org/link-types/citation`, …) where the relation maps, else NA |
| `relation` | DataCite relation as declared in Zenodo (`isSupplementTo`) |
| `scheme` | scheme of the external identifier |
| `target_type` | `resource_type` from Zenodo (e.g. `publication-article`) |
| `origin_in_corpus`, `target_in_corpus` | logical |
| `declared_on` | Zenodo record (version) the relation was declared on |

OpenAlex's link types (checked 2026-11-26, each mapped to DataCite terms): `citation`
(Cites, References), `part`, `component`, `data-series` (IsPartOf), `volume`
(IsPublishedIn), `review` (Reviews), `summary` (IsDerivedFrom, broad), `translation`
(IsTranslationOf), `withdrawal` (Withdrawn), `retraction`, `removal`.

**Orientation follows OpenAlex**: one row per link, in the direction "origin does X to
target". Relations Zenodo declares the other way round are flipped: `A isCitedBy B` →
origin B, target A, `citation`; `A hasPart B` → origin B, target A, `part`. So a link is
stored once, whichever side declared it, and no inverse rows are needed.

### 9.2 Normalisation

- DOIs: lowercase, strip `https://doi.org/`, `doi:`; URLs that are DOIs or Zenodo record
  URLs (`zenodo.org/records/<n>`, `/record/<n>`) are rewritten to their scheme.
- Zenodo DOIs (`10.5281/zenodo.<n>`): resolve locally to the deposit (record DOI → concept),
  so a relation to *a version* points to *the deposit*.
- arXiv → `10.48550/arXiv.<id>`; PMID, ISBN, handle, URL kept as they are.
- Duplicate relations across versions of one deposit collapse into one link (keep the
  newest `from_recid`).

### 9.3 Resolution

Within Zenodo only: targets that are Zenodo DOIs or record URLs resolve to the deposit
(`zenodo:<conceptrecid>`), whether or not it is in the corpus (`target_in_corpus`). All other
targets keep their normalised identifier; resolving them to OpenAlex is part of the later
enrichment (section 7). Zenodo targets outside the corpus can optionally be fetched
(`zenodo_expand()`, later; see 9.5).

### 9.4 What maps into OpenAlex columns

| Relation | Into |
|---|---|
| `cites`, `references` | `referenced_works` (`zenodo:` IDs of cited deposits in the corpus). This makes openalexAPI's `cites:` filter and openalexSnowball see these links; cited works outside the corpus stay in `zenodo_related` / the link table |
| `isCitedBy`, `isReferencedBy` | flipped to `citation` links from the citing work; if that work is a corpus deposit, it also goes into its `referenced_works` |
| `isVersionOf`, `hasVersion`, `isNewVersionOf`, `isPreviousVersionOf` | dropped from links between versions of the same deposit (covered by `zenodo_versions`); kept when they point outside the deposit (e.g. preprint ↔ published version) — used for matching (section 7) |
| `isIdenticalTo`, `isAlternateIdentifier` | `ids` and OpenAlex matching |
| `isSupplementTo`/`isSupplementedBy`, `isPartOf`/`hasPart`, `isDerivedFrom`/`isSourceOf`, `isDocumentedBy`/`documents`, `isDescribedBy`/`describes`, `compiles`/`isCompiledBy`, `requires`/`isRequiredBy`, `reviews`/`isReviewedBy`, `isPublishedIn`, `obsoletes`/`isObsoletedBy`, `isTranslationOf`/`hasTranslation`, … | `zenodo_related` + link table only |

A small `inst/extdata/relations.csv` (relation, active form, flip, link_type) holds the
whole vocabulary — one place to change.

### 9.5 Later

- `zenodo_expand(relation = …, depth = 1)`: fetch related Zenodo records that are not in
  any source (e.g. datasets supplementing community papers) into a source `expanded`.
- Hand the link table to openalexSnowball as an extra link source.
- Match `zenodo_references` (free text) to OpenAlex — only if needed; costly and fuzzy.

---

## 10. Exported API (sketch)

```r
zenodo_fetch(community = , query = , ids = , ..., select = NULL, project_folder, name = "zenodo", full = FALSE)
                                            # download / update raw (sections 3, 6)
zenodo_build(project_folder, name = "zenodo", versions = "latest", stats = FALSE)
                                            # map (Zenodo only) -> corpus, links
zenodo_update(project_folder, name = NULL, ...)  # fetch (stored arguments) + build
zenodo_as_corpus(project_folder, out, name = NULL, ...)  # subset export, as policy_as_corpus()
zenodo_links(project_folder, name = NULL, origin = NULL, target = NULL, link_type = NULL)
                                            # the link table, filtered as /links?filter=…
zenodo_download_files(project_folder, ids, pattern = "\\.pdf$")  # on request
```

Credentials: `API_zenodo_ro` only (keyring or environment variable, as now; 100 instead of 25 per page). No
OpenAlex key needed for the import.

Tests: no network (fixtures of saved hits; `file://` / mocked `httr2`), as in both siblings;
the offline pipeline tests of zenodo-openalex-collection (`tests/test_offline.R`) are copied in.

---

## 11. Phases

1. **v0.1 — raw**: package skeleton, copy the zenodo-openalex-collection core in (the
   original stays untouched), add search and ID sources, keep full `json`, `updated`
   watermark.
2. **v0.2 — corpus**: mapping tables (types, languages, licences, relations), Zenodo-only
   corpus, `zenodo_related`, link table, `referenced_works` from relations,
   `zenodo_as_corpus()`; check it with openalexAPI.
3. Later: `zenodo_expand()`, file download, openalexSnowball link input, OpenAlex
   enrichment as a separate step (section 7).

---

## 12. Decisions

Decided 2026-11-25:

- The deposit and the OpenAlex work are different records; `id` is always
  `zenodo:<conceptrecid>`; the import is based on Zenodo only; OpenAlex enrichment is a
  separate later step (section 7).
- **Q1**: one row per deposit by default; one row per version as import option
  `versions = "all"` (section 4).
- **Q2**: view and download counts only with import option `stats = TRUE` (default
  `FALSE`), stored with their date (`zenodo_stats`, `zenodo_stats_date`); see the note below.
- **Q3**: use Zenodo's new InvenioRDM format (section 8).
- **Q4**: public repository from the start.

### Note on Q2: view and download counts

**How they behave.** Zenodo's views and downloads (`stats`) grow continuously, independent of
edits: a record that nobody has edited since 2024 still gains views every day. Checked
2026-11-25: viewing does **not** change the record's `updated` date.

**So update detection does not see them, and that is good.** Updates are detected by record
counts per interval and by the `updated` date (section 6); neither moves when the counts
move. Popular records are therefore not re-downloaded every run.

**The consequence for stored counts.** A record's counts are refreshed only when that record
happens to be downloaded again (its interval changed, or it was edited). In the corpus,
one deposit's counts might be from today and another's from two years ago, so comparing
them across deposits would be misleading.

Hence: off by default; with `stats = TRUE` each row carries the date of its counts, so
their age is visible. Refreshing all of them means a full re-download (`full = TRUE`), at
the cost of the first import.
