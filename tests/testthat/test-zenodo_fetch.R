hits3 <- function() list(
  hit(11, 10, created = "2023-05-01T10:00:00+00:00", index = 1L, latest = FALSE),
  hit(12, 10, created = "2024-02-01T10:00:00+00:00", index = 2L),
  hit(21, 20, created = "2024-06-01T10:00:00+00:00")
)

test_that("first download stores records per year and the query record", {
  local_fake_zenodo(hits3())
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", from = "2023-01-01", to = "2025-01-01", project_folder = pf))
  dir <- file.path(pf, "raw", "zenodo")
  expect_setequal(list.files(dir), c("2023", "2024", "_query.json", "_query.html"))
  expect_equal(zenodo_part_counts(dir), c(`2023` = 1, `2024` = 2))
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

test_that("another query for the same name needs full = TRUE", {
  local_fake_zenodo(hits3())
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", project_folder = pf))
  expect_error(zenodo_fetch(community = "c", from = "2024-01-01", project_folder = pf), "other arguments")
  quiet(zenodo_fetch(community = "c", from = "2024-01-01", project_folder = pf, full = TRUE))
  dir <- file.path(pf, "raw", "zenodo")
  expect_equal(sort(zenodo_id_table(dir)$id), c("12", "21")) # 11 (2023) is outside now
  expect_equal(names(zenodo_part_counts(dir)), "2024")
})

test_that("the check interval can change in every call, without downloading", {
  z <- local_fake_zenodo(hits3())
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", from = "2023-01-01", to = "2025-01-01", project_folder = pf))
  expect_message(zenodo_fetch(community = "c", from = "2023-01-01", to = "2025-01-01", interval = "week",
                              project_folder = pf), "106 intervals checked \\(week\\).*0 to download")
  dir <- file.path(pf, "raw", "zenodo")
  expect_equal(jsonlite::read_json(file.path(dir, "_query.json"))$source$interval, "week")
  expect_equal(names(zenodo_part_counts(dir)), c("2023", "2024")) # storage unchanged
  # without `interval`: as last time; a change is downloaded by its week only
  z$hits <- c(z$hits, list(hit(31, created = "2024-06-03T10:00:00+00:00")))
  expect_message(zenodo_fetch(community = "c", from = "2023-01-01", to = "2025-01-01", project_folder = pf),
                 "1 to download: 2024-W23 \\(0 -> 1\\)")
  expect_equal(zenodo_part_counts(dir), c(`2023` = 1, `2024` = 3))
  rec <- jsonlite::read_json(file.path(dir, "_query.json"))
  expect_equal(unlist(rec$check$changed), "2024-W23")
})

test_that("a week across New Year is merged into both years", {
  z <- local_fake_zenodo(list(hit(1, created = "2024-12-31T10:00:00+00:00"),
                              hit(2, created = "2025-01-02T10:00:00+00:00"),
                              hit(3, created = "2025-03-01T10:00:00+00:00")))
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", interval = "week", project_folder = pf))
  dir <- file.path(pf, "raw", "zenodo")
  expect_equal(zenodo_part_counts(dir), c(`2024` = 1, `2025` = 2))
  z$hits <- c(z$hits[-1], list(hit(4, created = "2024-12-30T10:00:00+00:00"),
                               hit(5, created = "2025-01-01T10:00:00+00:00")))
  expect_message(zenodo_fetch(community = "c", project_folder = pf), "1 to download: 2025-W01 \\(2 -> 3\\)")
  expect_equal(zenodo_part_counts(dir), c(`2024` = 1, `2025` = 3))
  expect_setequal(zenodo_id_table(dir)$id, c("2", "3", "4", "5"))
})

test_that("a missing year (run stopped while merging) is repaired by the next run", {
  local_fake_zenodo(hits3())
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", project_folder = pf))
  dir <- file.path(pf, "raw", "zenodo")
  unlink(file.path(dir, "2023"), recursive = TRUE)
  expect_message(zenodo_fetch(community = "c", project_folder = pf), "1 to download: 2023 \\(0 -> 1\\)")
  expect_equal(sort(zenodo_id_table(dir)$id), c("11", "12", "21"))
})

test_that("the rolling recheck finds changes that cancel out within an interval", {
  z <- local_fake_zenodo(hits3())
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", from = "2024-01-01", to = "2025-01-01", recheck_interval = "month",
                     recheck_per_run = 12, project_folder = pf))
  dir <- file.path(pf, "raw", "zenodo")
  # 2024: one removed in February, one added in September -> same yearly count
  z$hits <- c(z$hits[c(1, 3)], list(hit(41, created = "2024-09-10T10:00:00+00:00")))
  expect_message(zenodo_fetch(community = "c", from = "2024-01-01", to = "2025-01-01", project_folder = pf),
                 "2 to download: 2024-02 \\(1 -> 0\\), 2024-09 \\(0 -> 1\\)")
  expect_setequal(zenodo_id_table(dir)$id, c("21", "41"))
  rec <- jsonlite::read_json(file.path(dir, "_query.json"))
  expect_equal(rec$recheck_last, "2024-12")
  # switched off, and dropped when not finer than a new interval
  quiet(zenodo_fetch(community = "c", from = "2024-01-01", to = "2025-01-01", recheck_per_run = 0, project_folder = pf))
  expect_null(jsonlite::read_json(file.path(dir, "_query.json"))$source$recheck)
})

test_that("downloads in the earlier layout (folder per interval) are converted", {
  local_fake_zenodo(hits3())
  pf <- local_project()
  dir <- file.path(pf, "raw", "zenodo")
  for (b in c("2023-05", "2024-02", "2024-06")) {
    dir.create(file.path(dir, b), recursive = TRUE)
    h <- Filter(function(x) substr(x$created, 1, 7) == b, hits3())
    arrow::write_parquet(zenodo_records(h), file.path(dir, b, "x_001.parquet"))
  }
  expect_message(zenodo_fetch(community = "c", project_folder = pf), "Converted")
  expect_equal(zenodo_part_counts(dir), c(`2023` = 1, `2024` = 2))
  expect_false(any(dir.exists(file.path(dir, c("2023-05", "2024-02", "2024-06")))))
})

test_that("stored records are counted per interval by created", {
  local_fake_zenodo(hits3())
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", project_folder = pf))
  b <- data.frame(from = c(NA, "2024-01-01", "2024-02-01T10:00:00", "2024-06-01T10:00:01"),
                  to = c("2024-01-01", "2024-02-01T10:00:00", NA, NA))
  expect_equal(stored_counts(file.path(pf, "raw", "zenodo"), b), c(1, 0, 2, 0))
  expect_equal(stored_counts(file.path(pf, "raw", "none"), b), c(0, 0, 0, 0))
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

test_that("an interrupted first download keeps what it has and resumes", {
  z <- local_fake_zenodo(list(
    hit(11, 10, created = "2022-05-01T10:00:00+00:00"),
    hit(21, 20, created = "2024-06-01T10:00:00+00:00")
  ))
  down <- TRUE # the network fails during the second run (2024)
  local_mocked_bindings(zenodo_get = function(url, ..., size = 25, q = NULL) {
    if (down && size > 1 && grepl("2024-01-01", q %||% "")) stop("network down")
    z$get(url, ..., size = size, q = q)
  })
  pf <- local_project()
  dir <- file.path(pf, "raw", "zenodo")
  args <- list(community = "c", from = "2022-01-01", to = "2025-01-01", project_folder = pf)
  expect_error(quiet(do.call(zenodo_fetch, args)), "network down")
  expect_equal(zenodo_id_table(dir)$id, "11") # the 2022 run was kept
  expect_false(dir.exists(paste0(dir, ".tmp")))
  expect_error(zenodo_fetch(community = "other", project_folder = pf), "other arguments")

  down <- FALSE
  expect_message(do.call(zenodo_fetch, args), "1 to download: 2024 \\(0 -> 1\\)")
  expect_equal(sort(zenodo_id_table(dir)$id), c("11", "21"))
  expect_false(is.null(jsonlite::read_json(file.path(dir, "_query.json"))$finished))
})

test_that("api_key is used for the call only and never stored", {
  z <- local_fake_zenodo(hits3())
  seen <- character()
  get <- z$get
  local_mocked_bindings(zenodo_get = function(url, ...) {
    seen <<- c(seen, zenodo_token())
    get(url, ...)
  })
  pf <- local_project()
  quiet(zenodo_fetch(community = "c", from = "2023-01-01", to = "2025-01-01",
                     project_folder = pf, api_key = "secret-token"))
  expect_true(length(seen) > 0 && all(seen == "secret-token"))
  expect_false(any(grepl("secret-token", readLines(file.path(pf, "raw", "zenodo", "_query.json")))))
  expect_equal(zenodo_token(), "") # restored: the mocked keyring has no key
  seen <- character()
  quiet(zenodo_update(pf, api_key = NULL))
  expect_true(length(seen) > 0 && all(seen == ""))
  expect_error(zenodo_fetch(community = "c", project_folder = pf, api_key = 1), "api_key")
})
