# CLAUDE.md

## What This Package Does

**openalexImportZenodo** downloads Zenodo records (communities, searches, record lists),
keeps them up to date incrementally, and writes a Zenodo-only works corpus in the OpenAlex
schema (`zenodo:<conceptrecid>` IDs) plus a link table shaped like OpenAlex's `/links`.
Second member of the `openalexImport<Source>` family. Design: `APPROACH.md`.

## Data flow

```
zenodo_fetch()  -> <project_folder>/raw/<name>/<interval>/*.parquet   (id columns + full hit as `json`)
                   raw/<name>/_query.json, _query.html                (arguments, last run, watermark)
zenodo_build()  -> corpus/query=<name>/data.parquet                   (one row per deposit)
                   links/query=<name>/data.parquet                    (origin, target, link_type, ...)
zenodo_update() =  zenodo_fetch() with stored arguments + zenodo_build()
```

| File | Role |
|---|---|
| `R/api.R` | `zenodo_get()` (InvenioRDM `Accept` header, throttle 2.2 s, 429 handling), token `API_zenodo_ro` |
| `R/intervals.R` | interval maths, copied unchanged from zenodo-openalex-collection |
| `R/source.R` | argument validation (`zenodo_source()`), query strings, URLs, ID resolution |
| `R/raw.R` | count check, range download with bisection, interval folders, `updated` upsert |
| `R/fetch.R` | `zenodo_fetch()`, `_query.json` / `_query.html` |
| `R/build.R` | `zenodo_build()`: DuckDB `json_transform()` + SQL mapping |
| `R/links.R` | link table (`build_links()`), `zenodo_links()` |
| `R/update.R` | `zenodo_update()`, `zenodo_as_corpus()` |
| `inst/extdata/` | `resource_types.csv`, `languages.csv` (from `data-raw/languages.R`), `relations.csv` |

## Key design decisions (keep these)

- Zenodo only: no OpenAlex request in the import. OpenAlex enrichment would be a separate step.
- `id` is always `zenodo:<conceptrecid>` (no `/`, unique when uppercased: openalexAPI's `id_key()`).
- Code copied from `~/GitHub/zenodo-openalex-collection` stays independent of it; do not edit that repo from here.
- Counts per interval are never stored: the check counts the rows of each interval folder.
- The full hit is kept in `json` (unless `select`), so mapping changes need no re-download.

## Commands

```r
devtools::load_all(); devtools::document(); devtools::test(); devtools::check()
```

Tests are offline: `helper-fake.R` replaces `zenodo_get()` with a fake Zenodo
(`local_fake_zenodo()`); `fixtures/hit_real.json` is one real InvenioRDM record (CC0 metadata).

## Branching

`claude/<description>` branches from `dev`; `main` gets release commits only.
