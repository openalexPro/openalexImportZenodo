test_that("the example corpus follows the ecosystem standard", {
  skip_if_not_installed("openalexStandard")
  corpus <- zenodo_example_corpus(withr::local_tempdir())
  openalexStandard::expect_compliant_corpus(corpus, api = FALSE)
})

test_that("openalexAPI can serve the example corpus", {
  skip_if_not_installed("openalexAPI")
  corpus <- zenodo_example_corpus(withr::local_tempdir())
  expect_no_error(openalexAPI::prepare_corpus(corpus, cache_dir = withr::local_tempdir()))
})
