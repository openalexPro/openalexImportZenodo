# openalexImportZenodo 0.0.0.9000

* Follows the openalexPro ecosystem standard (STANDARD.md 0.1;
  openalexPro/openalexPro_Ecosystem#6): the corpus folder gets a `_dataset.json` (writer,
  prefix `zenodo`, `id_format`), and `zenodo_example_corpus()` builds a small corpus offline
  from seven shipped IPBES deposits (used by the tests and the ecosystem's compliance checks).
* **Link table changes:** the extra columns carry the `zenodo_` prefix (`zenodo_relation`,
  `zenodo_relation_declared`, `zenodo_scheme`, `zenodo_related_type`,
  `zenodo_declared_on`); link ends that are neither a corpus deposit, a DOI nor a URL are
  written as `<scheme>:<identifier>` (e.g. `isbn:978-...`, `handle:...`); handles that are
  DOIs are written as DOIs; related identifiers of other schemes are no longer links (they
  stay in `zenodo_related`). Rebuild existing corpora with `zenodo_update()`.
* First version: `zenodo_fetch()` (communities, searches, record lists; incremental update by
  interval counts, rolling recheck and `updated` date), which also builds the Zenodo-only works
  corpus and link table, `zenodo_links()`, `zenodo_update()`, `zenodo_as_corpus()`.
* `api_key` argument of `zenodo_fetch()` and `zenodo_update()`, default `zenodo_api_key()`
  (as `pro_api_key()` in openalexPro).
