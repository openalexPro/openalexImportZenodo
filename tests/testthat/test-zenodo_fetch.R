hits3 <- function() list(
  hit(11, 10, created = "2023-05-01T10:00:00+00:00", index = 1L, latest = FALSE),
  hit(12, 10, created = "2024-02-01T10:00:00+00:00", index = 2L),
  hit(21, 20, created = "2024-06-01T10:00:00+00:00")
)

test_that("first download stores records per interval and the query record", {
  local_fake_zenodo(hits3())
  pf <- local_project()
  dir <- quiet(zenodo_fetch(community = "c", from = "2023-01-01", to = "2025-01-01", project_folder = pf))
  expect_setequal(list.files(dir), c("2023", "2024", "_query.json", "_query.html"))
  expect_equal(unname(zenodo_bucket_counts(dir)), c(1, 2))
  rec <- jsonlite::read_json(file.path(dir, "_query.json"))
  expect_equal(rec$records, 3)
  expect_equal(rec$deposits, 2)
  expect_equal(rec$last_change$added_deposits, 2)
  expect_equal(rec$source$community, "c")
  expect_match(paste(readLines(file.path(dir, "_query.html")), collapse = "\n"), "zenodo.org/communities/c/records")
})

test_that("only changed intervals are downloaded again; removals are seen", {
  z <- local_fake_zenodo(hits3())
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", from = "2023-01-01", to = "2025-01-01", project_folder = pf))
  dir <- file.path(pf, "raw", "zenodo")
  t2023 <- file.info(list.files(file.path(dir, "2023"), full.names = TRUE))$mtime
  z$hits <- z$hits[-3] # deposit 20 deleted on Zenodo
  Sys.sleep(1.1)
  expect_message(zenodo_fetch(community = "c", from = "2023-01-01", to = "2025-01-01", project_folder = pf),
                 "1 to download: 2024 \\(2 -> 1\\)")
  expect_equal(file.info(list.files(file.path(dir, "2023"), full.names = TRUE))$mtime, t2023)
  rec <- jsonlite::read_json(file.path(dir, "_query.json"))
  expect_equal(rec$last_change$removed_deposits, 1)
  expect_equal(sort(zenodo_id_table(dir)$id), c("11", "12"))
})

test_that("edited records replace their stored copies", {
  z <- local_fake_zenodo(hits3())
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", from = "2023-01-01", to = "2025-01-01", project_folder = pf))
  z$hits[[1]] <- hit(11, 10, created = "2023-05-01T10:00:00+00:00", latest = FALSE,
                     updated = format(Sys.time(), "%Y-%m-%dT%H:%M:%S+00:00", tz = "UTC"),
                     title = "Edited")
  quiet(zenodo_fetch(community = "c", from = "2023-01-01", to = "2025-01-01", project_folder = pf))
  d <- zenodo_id_table(file.path(pf, "raw", "zenodo"), c("id", "json"))
  expect_equal(nrow(d), 3)
  expect_equal(jsonlite::fromJSON(d$json[d$id == "11"])$metadata$title, "Edited")
  rec <- jsonlite::read_json(file.path(pf, "raw", "zenodo", "_query.json"))
  expect_equal(rec$last_change$edited_records, 1)
})

test_that("other arguments for the same name need full = TRUE", {
  local_fake_zenodo(hits3())
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", project_folder = pf))
  expect_error(zenodo_fetch(community = "c", interval = "month", project_folder = pf), "other arguments")
  quiet(zenodo_fetch(community = "c", interval = "month", project_folder = pf, full = TRUE))
  dir <- file.path(pf, "raw", "zenodo")
  expect_setequal(names(zenodo_bucket_counts(dir)), c("2023-05", "2024-02", "2024-06"))
  expect_equal(jsonlite::read_json(file.path(dir, "_query.json"))$source$interval, "month")
})

test_that("ids are resolved to deposits once and stored", {
  z <- local_fake_zenodo(hits3())
  local_mocked_bindings(zenodo_resolve_ids = function(ids) "10")
  pf <- local_project()
  quiet(zenodo_fetch(ids = "10.5281/zenodo.12", interval = "all", project_folder = pf, name = "refs"))
  dir <- file.path(pf, "raw", "refs")
  expect_setequal(zenodo_id_table(dir)$id, c("11", "12"))
  expect_equal(unlist(jsonlite::read_json(file.path(dir, "_query.json"))$source$parents), "10")
})

test_that("select stores only the given parts", {
  local_fake_zenodo(hits3())
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", select = "metadata.title", project_folder = pf))
  j <- jsonlite::fromJSON(zenodo_id_table(file.path(pf, "raw", "zenodo"), "json")$json[1])
  expect_equal(names(j$metadata), "title")
  expect_null(j$stats)
})

test_that("bad names are refused", {
  expect_error(zenodo_fetch(community = "c", project_folder = tempdir(), name = "a/b"), "one word")
})
