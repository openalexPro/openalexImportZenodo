test_that("links are oriented like OpenAlex, deduplicated and resolved", {
  hits <- list(
    hit(11, 10, index = 1L, latest = FALSE, related = list(
      rel("10.5281/zenodo.21", "cites"),            # version of a deposit in the corpus
      rel("10.5281/zenodo.12", "isnewversionof"))),  # own version: dropped
    hit(12, 10, index = 2L, related = list(
      rel("https://doi.org/10.5281/zenodo.21", "cites"), # same link again, newer version
      rel("10.1234/ABC", "iscitedby"),
      rel("2101.00001", "issupplementto", scheme = "arxiv"),
      rel("https://zenodo.org/records/20", "haspart", scheme = "url"))),
    hit(21, 20, related = list(rel("10.5281/zenodo.10", "iscitedby"))) # declared by both sides
  )
  local_fake_zenodo(hits)
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", project_folder = pf))
  quiet(zenodo_build(pf))
  l <- zenodo_links(pf)
  key <- paste(l$origin, l$relation, l$target)
  expect_setequal(key, c(
    "zenodo:10 cites zenodo:20",
    "https://doi.org/10.1234/abc cites zenodo:10",
    "zenodo:10 isSupplementTo https://doi.org/10.48550/arxiv.2101.00001",
    "zenodo:20 isPartOf zenodo:10"))
  cit <- l[l$relation == "cites" & l$target == "zenodo:20", ]
  expect_equal(cit$link_type, "https://openalex.org/link-types/citation")
  expect_equal(cit$declared_on, "12")
  expect_true(is.na(l$link_type[l$relation == "isSupplementTo"]))
  expect_equal(nrow(zenodo_links(pf, link_type = "part")), 1)
  expect_equal(nrow(zenodo_links(pf, target = "zenodo:10")), 2)
  w <- arrow::read_parquet(file.path(pf, "corpus", "query=zenodo", "data.parquet"))
  expect_equal(w$referenced_works[[which(w$id == "zenodo:10")]], "zenodo:20")
  expect_length(w$referenced_works[[which(w$id == "zenodo:20")]], 0)
})
