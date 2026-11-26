# Ported from zenodo-openalex-collection tests/test_offline.R.

test_that("interval labels and starts round-trip", {
  expect_equal(zenodo_bucket_label("2024-12-30T10:00:00", "week"), "2025-W01")
  expect_equal(zenodo_bucket_label("2024-05-10", "month"), "2024-05")
  expect_equal(zenodo_bucket_label("2024-05-10", "quarter"), "2024-Q2")
  expect_equal(zenodo_bucket_label("2024-05-10", "year"), "2024")
  expect_equal(zenodo_bucket_label(c("2024-05-10", "2020-01-01"), "all"), c("all", "all"))
  expect_identical(zenodo_bucket_start(c("2025-W01", "2024-05", "2024-Q2", "2024", "all")),
                   c("2024-12-30", "2024-05-01", "2024-04-01", "2024-01-01", NA))
  for (iv in c("week", "month", "quarter", "year")) {
    d <- as.character(seq(as.Date("2019-12-20"), as.Date("2021-01-10"), by = "day"))
    lab <- unique(zenodo_bucket_label(d, iv))
    expect_identical(zenodo_bucket_label(zenodo_bucket_start(lab), iv), lab)
  }
})

test_that("buckets cover the range", {
  b <- zenodo_buckets(list(from = "2024-01-15", to = "2024-04-01", interval = "month"))
  expect_identical(b$bucket, c("2024-01", "2024-02", "2024-03"))
  expect_identical(b$from, c("2024-01-15", "2024-02-01", "2024-03-01"))
  expect_identical(b$to, c("2024-02-01", "2024-03-01", "2024-04-01"))
  w <- zenodo_buckets(list(from = "2025-01-01", to = "2025-01-20", interval = "week"))
  expect_identical(w$bucket, c("2025-W01", "2025-W02", "2025-W03"))
  expect_identical(zenodo_buckets(list(interval = "all"))$bucket, "all")
  y <- zenodo_buckets(list(from = "2023-06-01", interval = "year"))
  expect_equal(y$bucket[1], "2023")
  expect_true(is.na(y$to[nrow(y)]))
})

test_that("overlaps mark every storage interval a finer one touches", {
  storage <- data.frame(bucket = c("2024-01", "2024-02", "2024-03"),
                        from = c("2024-01-01", "2024-02-01", "2024-03-01"),
                        to = c("2024-02-01", "2024-03-01", NA))
  wk <- data.frame(bucket = "2024-W05", from = "2024-01-29", to = "2024-02-05")
  expect_identical(zenodo_overlaps(wk, storage), c("2024-01", "2024-02"))
  expect_identical(zenodo_overlaps(data.frame(bucket = "x", from = "2030-01-01", to = NA), storage), "2024-03")
  expect_length(zenodo_overlaps(wk[0, ], storage), 0)
})

test_that("rolling recheck walks through the finer intervals", {
  fine <- data.frame(bucket = paste0("b", 1:5))
  expect_identical(recheck_select(fine, 2)$bucket, c("b1", "b2"))
  expect_identical(recheck_select(fine, 2, "b2")$bucket, c("b3", "b4"))
  expect_identical(recheck_select(fine, 2, "b5")$bucket, c("b1", "b2"))
  expect_identical(recheck_select(fine, 2, "b4")$bucket, c("b5", "b1"))
  expect_identical(recheck_select(fine, 2, "gone")$bucket, c("b1", "b2"))
  expect_identical(recheck_select(fine, 9)$bucket, fine$bucket)
})
