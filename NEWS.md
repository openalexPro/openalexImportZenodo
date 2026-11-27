# openalexImportZenodo 0.0.0.9000

* First version: `zenodo_fetch()` (communities, searches, record lists; incremental update by
  interval counts, rolling recheck and `updated` date), which also builds the Zenodo-only works
  corpus and link table, `zenodo_links()`, `zenodo_update()`, `zenodo_as_corpus()`.
* `api_key` argument of `zenodo_fetch()` and `zenodo_update()`, default `zenodo_api_key()`
  (as `pro_api_key()` in openalexPro).
