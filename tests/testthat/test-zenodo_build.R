build_from <- function(hits, ..., name = "zenodo", select = NULL, env = parent.frame()) {
  local_fake_zenodo(hits, env = env)
  pf <- local_project(env)
  quiet(zenodo_fetch(community = "c", select = select, project_folder = pf, name = name))
  quiet(zenodo_build(pf, name, ...))
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

test_that("no records, no build", {
  expect_error(zenodo_build(local_project()), "zenodo_fetch")
})
