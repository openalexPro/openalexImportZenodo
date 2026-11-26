# openalexImportZenodo

<!-- badges: start -->
[![Status: alpha](https://img.shields.io/badge/status-alpha%20(at%20most)-red.svg)](https://github.com/openalexPro/openalexImportZenodo)
[![CI dev](https://img.shields.io/github/actions/workflow/status/openalexPro/openalexImportZenodo/R-CMD-check.yaml?branch=dev&label=CI%20dev)](https://github.com/openalexPro/openalexImportZenodo/actions/workflows/R-CMD-check.yaml?query=branch%3Adev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
<!-- badges: end -->

> [!WARNING]
> **Alpha at most — do not rely on it.** This package is a first implementation of a
> design ([APPROACH.md](APPROACH.md)) and has been tried on a handful of Zenodo
> communities and searches only. There is **no release**, no DOI, no documentation site and
> no guarantee: function names, arguments, the folder layout and the columns of the corpus
> **will change** without notice and without a migration path. Data written by one version
> may have to be downloaded again with the next. It is not on r-universe. Use it to try
> things out and to give feedback, not for work you need to reproduce.

**openalexImportZenodo** downloads the records of Zenodo communities, Zenodo searches or
lists of Zenodo records, keeps them up to date without downloading everything again, and
writes them as a works corpus in the OpenAlex schema, so that the openalexPro packages (e.g.
openalexAPI) can use them. Zenodo's related identifiers (the paper a dataset supplements, the
chapters of a report, …) become a link table shaped like OpenAlex's
[`/links`](https://api.openalex.org/links). Only Zenodo is used; nothing is requested from
OpenAlex.

## Installation

Only from the `dev` branch on GitHub:

```r
pak::pak("openalexPro/openalexImportZenodo@dev")
```

A Zenodo token (no scopes needed, from
[zenodo.org/account/settings/applications](https://zenodo.org/account/settings/applications))
in the environment variable or keyring entry `API_zenodo_ro` allows 100 instead of 25 records
per request.

## Use

```r
library(openalexImportZenodo)

# Download (first call) or update (later calls) a community; the corpus
# (proj/corpus/) and the link table (proj/links/) are built right away
zenodo_fetch(community = "ipbes", project_folder = "proj")

# A search, as a second source in the same project folder
zenodo_fetch(query = "bats AND switzerland", resource_type = "dataset",
             project_folder = "proj", name = "bats", interval = "all")

# Search it in the browser (openalexAPI), at http://127.0.0.1:8000/app
openalexAPI::serve_corpus("proj/corpus", port = 8000)

# Links into a deposit
zenodo_links("proj", target = "zenodo:13850301")

# Later: update every source with its stored arguments and rebuild;
# the check interval can be chosen per call (week, month, quarter, year, all)
zenodo_update("proj")
zenodo_fetch(community = "ipbes", project_folder = "proj", interval = "month")
```

Each deposit (all versions of a Zenodo upload) is one work with `id` `zenodo:<concept record
ID>`. `proj/raw/<name>/_query.html` shows what was asked and the last run.

The design, the field mapping and the decisions behind them are in
[APPROACH.md](APPROACH.md).

## License

MIT. Zenodo metadata is CC0; the files of Zenodo records keep their own licences.
