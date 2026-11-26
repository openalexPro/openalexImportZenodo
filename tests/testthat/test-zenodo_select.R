test_that("select keeps the given paths and the identity fields", {
  h <- hit(1, related = list(rel("10.1/x", "cites")))
  s <- zenodo_select(h, c("metadata.title", "stats", "metadata.nope", "nope.deeper"))
  expect_setequal(names(s), c(zenodo_keep[zenodo_keep %in% names(h)], "metadata", "stats"))
  expect_equal(names(s$metadata), "title")
  expect_identical(zenodo_select(h, NULL), h)
})
