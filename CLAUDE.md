# CLAUDE.md

## What This Package Does

**openalexImportZenodo** downloads Zenodo records (communities, searches, record lists),
keeps them up to date incrementally, and writes a Zenodo-only works corpus in the OpenAlex
schema (`zenodo:<conceptrecid>` IDs) plus a link table shaped like OpenAlex's `/links`.
Second member of the `openalexImport<Source>` family. Design: `APPROACH.md`.

## Data flow

```
zenodo_fetch()  -> <project_folder>/raw/<name>/<part>/*.parquet       (all versions by year (or parquet_split period) of `created`; id columns + full hit as `json`)
                   raw/<name>/_query.json, _query.html                (arguments, last run, watermark)
zenodo_build()  -> corpus/query=<name>/data.parquet                   (one row per deposit; + copies of _query.json/.html)
                   links/query=<name>/data.parquet                    (origin, target, link_type, ...)
zenodo_fetch() calls zenodo_build() (internal) at the end (like pro_fetch(): a usable dataset after each call)
zenodo_update() =  zenodo_fetch() with the stored arguments (incl. versions / stats)
```

| File | Role |
|---|---|
| `R/api.R` | `zenodo_get()` (InvenioRDM `Accept` header, throttle 2.2 s, 429 handling), token `API_zenodo_ro` |
| `R/intervals.R` | interval maths, copied unchanged from zenodo-openalex-collection |
| `R/source.R` | argument validation (`zenodo_source()`), query strings, URLs, ID resolution |
| `R/raw.R` | count check (stored counts by `created`, any interval), range download with bisection, merge into part folders (year, or `parquet_split` period) in one partitioned COPY, `updated` upsert, layout conversion |
| `R/fetch.R` | `zenodo_fetch()`, `_query.json` / `_query.html` |
| `R/build.R` | `zenodo_build()` (internal; its user docs live in `zenodo_fetch()`'s help): DuckDB `json_transform()` + SQL mapping |
| `R/links.R` | link table (`build_links()`), `zenodo_links()` |
| `R/update.R` | `zenodo_update()`, `zenodo_as_corpus()` |
| `inst/extdata/` | `resource_types.csv`, `languages.csv` (from `data-raw/languages.R`), `relations.csv` |

## Key design decisions (keep these)

- Zenodo only: no OpenAlex request in the import. OpenAlex enrichment would be a separate step.
- `id` is always `zenodo:<conceptrecid>` (no `/`, unique when uppercased: openalexAPI's `id_key()`).
- Code copied from `~/GitHub/zenodo-openalex-collection` stays independent of it; do not edit that repo from here.
- Storage (year folders) and the check interval are independent: the interval can change in every call; counts are never stored, they are counted from `created` (UTC, fixed format, compared as text).
- The full hit is kept in `json` (unless `select`), so mapping changes need no re-download.

## Commands

```r
devtools::load_all(); devtools::document(); devtools::test(); devtools::check()
```

Tests are offline: `helper-fake.R` replaces `zenodo_get()` with a fake Zenodo
(`local_fake_zenodo()`); `fixtures/hit_real.json` is one real InvenioRDM record (CC0 metadata).

## Branching

`claude/<description>` branches from `dev`; `main` gets release commits only.
