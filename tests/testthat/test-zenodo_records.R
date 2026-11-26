test_that("hits become one row per record with the full JSON", {
  d <- zenodo_records(list(hit(11, 10, index = 2L), hit(12, 12, conceptdoi = FALSE)))
  expect_equal(d$id, c("11", "12"))
  expect_equal(d$conceptrecid, c("10", "12"))
  expect_equal(d$conceptdoi, c("10.5281/zenodo.10", NA))
  expect_equal(d$version_index, c(2L, 1L))
  expect_equal(jsonlite::fromJSON(d$json[1])$metadata$title, "Record 11")
  expect_equal(zenodo_deposit(d$conceptdoi, d$doi), c("10.5281/zenodo.10", "10.5281/zenodo.12"))
})

test_that("the real InvenioRDM record is read", {
  h <- jsonlite::read_json(test_path("fixtures", "hit_real.json"))
  d <- zenodo_records(list(h))
  expect_false(anyNA(d[c("id", "conceptrecid", "doi", "created", "updated", "version_index", "is_latest")]))
})
