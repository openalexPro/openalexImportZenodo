test_that("exactly one of community, query, ids", {
  expect_error(zenodo_source(), "exactly one")
  expect_error(zenodo_source(community = "a", query = "b"), "exactly one")
  expect_equal(zenodo_source(community = "a")$community, "a")
  expect_equal(zenodo_source(ids = c(1, 2))$ids, c("1", "2"))
})

test_that("arguments are validated", {
  expect_error(zenodo_source(community = c("a", "b")), "single string")
  expect_error(zenodo_source(community = "a", interval = "day"), "interval")
  expect_error(zenodo_source(community = "a", recheck_interval = "month"), "both")
  expect_error(zenodo_source(community = "a", interval = "month", recheck_interval = "month",
                             recheck_per_run = 2), "finer")
  expect_error(zenodo_source(community = "a", interval = "month", recheck_interval = "week",
                             recheck_per_run = 0), "positive")
  expect_error(zenodo_source(community = "a", select = ""), "without empty")
  s <- zenodo_source(community = "a", interval = "month", recheck_interval = "week", recheck_per_run = 2)
  expect_equal(s$recheck, list(interval = "week", per_run = 2L))
})
