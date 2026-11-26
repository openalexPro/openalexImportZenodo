test_that("query parts are combined with the created window", {
  expect_equal(zenodo_query(zenodo_source(community = "x")), "created:[* TO *}")
  expect_equal(zenodo_query(zenodo_source(community = "x"), "2024-01-01", "2025-01-01"),
               'created:["2024-01-01" TO "2025-01-01"}')
  s <- zenodo_source(query = "bats AND swiss", communities = c("a", "b"))
  expect_equal(zenodo_query(s, NULL, "2025-01-01"),
               '(bats AND swiss) AND parent.communities.entries.slug:(a OR b) AND created:[* TO "2025-01-01"}')
  s <- zenodo_source(ids = "1"); s$parents <- c("1", "7")
  expect_equal(zenodo_query(s), "parent.id:(1 OR 7) AND created:[* TO *}")
})

test_that("URLs point to the community or the search", {
  expect_equal(zenodo_url(zenodo_source(community = "ipbes")), "https://zenodo.org/api/communities/ipbes/records")
  expect_equal(zenodo_url(zenodo_source(query = "x")), "https://zenodo.org/api/records")
  w <- zenodo_web_url(zenodo_source(query = "bats", resource_type = "dataset"))
  expect_match(w, "^https://zenodo.org/search\\?q=%28bats%29&all_versions=true&f=resource_type%3Adataset$")
  expect_match(zenodo_web_url(zenodo_source(community = "ipbes")), "^https://zenodo.org/communities/ipbes/records\\?q=&")
})
