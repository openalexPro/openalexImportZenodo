# Builds inst/extdata/example/: the stored records of a few deposits of the IPBES
# Zenodo community (metadata, CC0), for zenodo_example_corpus() (ecosystem standard P7).
# Chosen so the example exercises citations between deposits, versions, and link ends
# outside the corpus (DOI, handle, ISBN). Source: a local zenodo_fetch(community = "ipbes")
# into ipbes_zenodo/ (not in git).
deposits <- c("11579456", "3826766", "6322965", "3630390", "3551078", "5509137", "6418520")
src <- "ipbes_zenodo/raw/zenodo"
out <- "inst/extdata/example/raw/example"
unlink(out, recursive = TRUE)
dir.create(out, recursive = TRUE)
con <- DBI::dbConnect(duckdb::duckdb())
files <- list.files(src, "[.]parquet$", recursive = TRUE, full.names = TRUE)
DBI::dbExecute(con, sprintf(
  "COPY (SELECT * FROM read_parquet([%s]) WHERE conceptrecid IN (%s) ORDER BY conceptrecid, id)
   TO '%s' (FORMAT parquet, COMPRESSION zstd)",
  paste0("'", files, "'", collapse = ", "), paste0("'", deposits, "'", collapse = ", "),
  file.path(out, "records.parquet")))
DBI::dbDisconnect(con, shutdown = TRUE)
rec <- jsonlite::read_json(file.path(src, "_query.json"))
rec$note <- "Example: a few deposits of the IPBES community, see data-raw/example_corpus.R"
rec$build <- list(versions = "latest", stats = FALSE, parquet_split = "none")
jsonlite::write_json(rec, file.path(out, "_query.json"), auto_unbox = TRUE, pretty = TRUE, null = "null")
file.copy(file.path(src, "_query.html"), out, overwrite = TRUE)
