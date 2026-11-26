# zenodo_fetch() builds the corpus itself
build_from <- function(hits, ..., name = "zenodo", select = NULL, env = parent.frame()) {
  local_fake_zenodo(hits, env = env)
  pf <- local_project(env)
  quiet(zenodo_fetch(community = "c", select = select, project_folder = pf, name = name, ...))
  pf
}
works <- function(pf, name = "zenodo") {
  as.data.frame(arrow::read_parquet(file.path(pf, "corpus", paste0("query=", name), "data.parquet")))
}

test_that("one row per deposit from its newest version", {
  pf <- build_from(list(hit(11, 10, index = 1L, latest = FALSE, title = "old"),
                        hit(12, 10, index = 2L, title = "new"),
                        hit(21, 20, conceptdoi = FALSE)))
  w <- works(pf)
  expect_equal(w$id, c("zenodo:10", "zenodo:20"))
  expect_equal(w$title, c("new", "Record 21"))
  expect_equal(w$doi, c("https://doi.org/10.5281/zenodo.10", "https://doi.org/10.5281/zenodo.21"))
  expect_equal(nrow(w$zenodo_versions[[1]]), 2)
  expect_equal(w$abstract[1], "An abstract & more")
  expect_equal(w$type, c("dataset", "dataset"))
  expect_equal(w$primary_location$license, c("cc-by", "cc-by"))
  expect_equal(w$primary_location$pdf_url[1], "https://zenodo.org/records/12/files/paper.pdf")
  expect_equal(w$zenodo_sources[[1]], "zenodo")
  expect_false(any(grepl("/", sub("^zenodo:", "", w$id))))
  expect_false("zenodo_stats" %in% names(w))
})

test_that("versions = 'all' and stats", {
  pf <- build_from(list(hit(11, 10, index = 1L, latest = FALSE), hit(12, 10, index = 2L)),
                   versions = "all", stats = TRUE)
  w <- works(pf)
  expect_equal(w$id, c("zenodo:11", "zenodo:12"))
  expect_equal(w$zenodo_stats$all_versions$views, c(5, 5))
  expect_false(anyNA(w$zenodo_stats_date))
})

test_that("records stored with select build with empty fields", {
  pf <- build_from(list(hit(11)), select = "metadata.title")
  w <- works(pf)
  expect_equal(w$title, "Record 11")
  expect_true(is.na(w$abstract))
})

test_that("the real InvenioRDM record is mapped", {
  h <- jsonlite::read_json(test_path("fixtures", "hit_real.json"))
  pf <- build_from(list(h))
  w <- works(pf)
  expect_equal(w$id, paste0("zenodo:", h$parent$id))
  for (col in c("title", "abstract", "publication_date", "language", "type")) {
    expect_false(is.na(w[[col]]), label = col)
  }
  a <- w$authorships[[1]]
  expect_equal(a$author_position[1], "first")
  expect_true(any(!is.na(a$author$orcid)))
  expect_true(any(lengths(lapply(a$institutions, function(x) x$ror)) > 0))
  expect_gt(nrow(w$zenodo_related[[1]]), 0)
})

test_that("zenodo_fetch() returns the built files; zenodo_build() rebuilds with other options", {
  local_fake_zenodo(list(hit(11, 10, index = 1L, latest = FALSE), hit(12, 10, index = 2L)))
  pf <- local_project()
  out <- quiet(zenodo_fetch(community = "c", project_folder = pf))
  expect_named(out, c("corpus", "links"))
  expect_true(all(dir.exists(out)))
  expect_setequal(list.files(out[["corpus"]]), c("data.parquet", "_query.json", "_query.html"))
  expect_identical(readLines(file.path(out[["corpus"]], "_query.json")),
                   readLines(file.path(pf, "raw", "zenodo", "_query.json")))
  expect_equal(nrow(arrow::read_parquet(file.path(out[["corpus"]], "data.parquet"))), 1)
  quiet(zenodo_build(pf, versions = "all"))
  expect_equal(nrow(arrow::read_parquet(file.path(out[["corpus"]], "data.parquet"))), 2)
  # the setting is kept: the next fetch builds with versions = "all" too
  expect_equal(jsonlite::read_json(file.path(pf, "raw", "zenodo", "_query.json"))$build$versions, "all")
  quiet(zenodo_fetch(community = "c", project_folder = pf))
  expect_equal(nrow(arrow::read_parquet(file.path(out[["corpus"]], "data.parquet"))), 2)
})

test_that("no records, no corpus", {
  expect_error(zenodo_build(local_project()), "zenodo_fetch")
  z <- local_fake_zenodo(list(hit(11)))
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", project_folder = pf))
  z$hits <- list()
  expect_null(quiet(zenodo_fetch(community = "c", project_folder = pf)))
  expect_false(dir.exists(file.path(pf, "corpus", "query=zenodo")))
})

test_that("parquet_split splits corpus, links and raw/ by period of the creation date", {
  hits <- list(
    hit(11, 10, created = "2024-01-10T10:00:00+00:00", index = 1L, latest = FALSE,
        related = list(rel("10.5281/zenodo.21", "cites"))),
    hit(12, 10, created = "2024-05-10T10:00:00+00:00", index = 2L), # new version: stays in 2024-Q1
    hit(21, 20, created = "2024-04-02T10:00:00+00:00"),
    hit(31, 30, created = "2025-02-01T10:00:00+00:00")
  )
  local_fake_zenodo(hits)
  pf <- local_project()
  out <- quiet(zenodo_fetch(community = "c", parquet_split = "quarter", project_folder = pf))
  expect_setequal(list.files(out[["corpus"]], "parquet$"), c("2024-Q1.parquet", "2024-Q2.parquet", "2025-Q1.parquet"))
  expect_equal(arrow::read_parquet(file.path(out[["corpus"]], "2024-Q1.parquet"))$id, "zenodo:10")
  expect_equal(list.files(out[["links"]], "parquet$"), "2024-Q1.parquet") # declared by deposit 10
  expect_setequal(list.files(file.path(pf, "raw", "zenodo")),
                  c("2024-Q1", "2024-Q2", "2025-Q1", "_query.json", "_query.html"))
  expect_equal(nrow(arrow::open_dataset(out[["corpus"]])), 3)
  expect_equal(nrow(zenodo_links(pf)), 1)

  # another split: raw/ is rewritten locally, without downloading
  expect_message(zenodo_fetch(community = "c", parquet_split = "year", project_folder = pf), "Converted")
  expect_setequal(list.files(out[["corpus"]], "parquet$"), c("2024.parquet", "2025.parquet"))
  expect_equal(names(zenodo_part_counts(file.path(pf, "raw", "zenodo"))), c("2024", "2025"))
  expect_equal(sort(zenodo_id_table(file.path(pf, "raw", "zenodo"))$id), c("11", "12", "21", "31"))
})

test_that("parquet_split as a number gives files of about that many works", {
  hits <- lapply(1:30, function(i) hit(i, created = sprintf("2024-01-%02dT10:00:00+00:00", i)))
  local_fake_zenodo(hits)
  pf <- local_project()
  out <- quiet(zenodo_fetch(community = "c", parquet_split = 10, project_folder = pf))
  f <- list.files(out[["corpus"]], "parquet$", full.names = TRUE)
  expect_true(all(grepl("^part_[0-9]+\\.parquet$", basename(f))))
  expect_equal(sum(vapply(f, function(x) nrow(arrow::read_parquet(x)), 1)), 30)
  expect_equal(list.files(file.path(pf, "raw", "zenodo"), "^[0-9]"), "2024") # raw/: years
  expect_error(zenodo_fetch(community = "c", parquet_split = "week", project_folder = pf), "parquet_split")
})

test_that("building in small batches gives the same corpus and links", {
  hits <- list(hit(11, 10, created = "2023-05-01T10:00:00+00:00", index = 1L, latest = FALSE),
               hit(12, 10, created = "2024-02-01T10:00:00+00:00", index = 2L,
                   related = list(rel("10.5281/zenodo.21", "cites"))),
               hit(21, 20, created = "2024-06-01T10:00:00+00:00"),
               hit(31, 30, created = "2024-06-01T10:00:00+00:00"), # same `created` as 21
               hit(41, 40, created = "2025-01-01T10:00:00+00:00"))
  pf <- build_from(hits)
  one <- works(pf)
  local_mocked_bindings(build_batch = 2)
  quiet(zenodo_build(pf))
  many <- works(pf)
  expect_setequal(many$id, one$id)
  expect_equal(many[order(many$id), ], one, ignore_attr = TRUE)
  expect_equal(many$referenced_works[many$id == "zenodo:10"][[1]], "zenodo:20")
  expect_equal(nrow(zenodo_links(pf)), 1)
  expect_false(dir.exists(file.path(pf, "raw", "zenodo.build")))
})
