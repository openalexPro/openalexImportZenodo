# Ported from zenodo-openalex-collection tests/test_offline.R.
range_hits <- function(created) {
  lapply(seq_along(created), function(i) hit(i, created = paste0(created[i], "+00:00")))
}
run_range <- function(created, from, to, limit, chunk = 50) {
  z <- local_fake_zenodo(range_hits(created), env = parent.frame())
  dir <- withr::local_tempdir(.local_envir = parent.frame())
  n <- quiet(fetch_zenodo_range(zenodo_source(community = "x"), dir, from, to, limit = limit, chunk = chunk))
  d <- zenodo_id_table(dir, c("id", "created"))
  list(n = n, ids = sort(as.integer(d$id)), files = list.files(dir), calls = z$calls)
}

test_that("a dense day is bisected to sub-hour pieces", {
  set.seed(1)
  day <- as.POSIXct("2017-02-08", tz = "UTC")
  created <- format(c(day + sort(stats::runif(350, 0, 86399)), day + 43200 + 0:49), "%Y-%m-%dT%H:%M:%S")
  r <- run_range(created, "2017-02-01", "2017-03-01", limit = 100)
  expect_equal(r$n, 400)
  expect_identical(r$ids, seq_along(created))
  expect_lt(r$calls, 200)
  expect_true(any(grepl("T[0-9]{6}_", r$files)))
})

test_that("open range is chunked into files", {
  created <- format(as.POSIXct("2017-02-08", tz = "UTC") + 1:90 * 60, "%Y-%m-%dT%H:%M:%S")
  r <- run_range(created, NULL, NULL, limit = 100, chunk = 25)
  expect_equal(r$n, 90)
  expect_identical(r$files, sprintf("start_now_%03d.parquet", 1:4))
})

test_that("10,000+ records within one second stop", {
  expect_error(run_range(rep("2017-02-08T12:00:00", 150), "2017-02-08", "2017-02-09", limit = 100),
               "within one second")
})

test_that("an extra condition (edited records) is kept while splitting", {
  day <- as.POSIXct("2017-02-08", tz = "UTC")
  created <- format(day + 1:150 * 300, "%Y-%m-%dT%H:%M:%S+00:00")
  hits <- lapply(seq_along(created), function(i) {
    hit(i, created = created[i], updated = if (i <= 120) "2026-01-05T00:00:00+00:00" else created[i])
  })
  local_fake_zenodo(hits)
  dir <- withr::local_tempdir()
  n <- quiet(fetch_zenodo_range(zenodo_source(community = "x"), dir, "2017-02-08", "2017-02-09",
                                limit = 100, extra = 'updated:["2026-01-01" TO *]'))
  expect_equal(n, 120)
  expect_equal(sort(as.integer(zenodo_id_table(dir)$id)), 1:120)
})
