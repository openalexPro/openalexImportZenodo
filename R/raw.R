# The raw store: raw/<name>/<year>/*.parquet, one row per record (version), by year of
# `created`, with the ID columns and the full hit as JSON. Storage does not depend on the
# check interval: the check counts stored records per interval by `created`, so any interval
# can be checked at any time; changed intervals are downloaded and merged into their years.
# Started from zenodo-openalex-collection (fetch_zenodo_range.R, fetch_zenodo.R,
# check_zenodo.R, zenodo_records.R, zenodo_id_table.R, zenodo_deposit.R); adapted:
# InvenioRDM fields, `json` column, year folders with merge, state returned instead of written.
#
# `created` is UTC in one fixed format ("2024-03-01T10:00:00.123456+00:00"), so it is
# compared as text with interval limits ("2024-03-01", "2024-03-01T10:00:00").

# Zenodo search hits -> one row per record (version). `json`: the hit as returned, or only
# the `select`ed paths plus the identity fields.
zenodo_records <- function(hits, select = NULL, fetched = Sys.time()) {
  chr <- function(f) vapply(hits, function(h) as.character(f(h) %||% NA_character_)[1], "")
  data.frame(
    id = chr(function(h) h$id),
    conceptrecid = chr(function(h) h$parent$id),
    doi = chr(function(h) h$pids$doi$identifier),
    conceptdoi = chr(function(h) h$parent$pids$doi$identifier),
    created = chr(function(h) h$created),
    updated = chr(function(h) h$updated),
    version_index = vapply(hits, function(h) as.integer(h$versions$index %||% NA_integer_), 1L),
    is_latest = vapply(hits, function(h) as.logical(h$versions$is_latest %||% NA), NA),
    fetched = format(fetched, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    json = vapply(hits, function(h) {
      as.character(jsonlite::toJSON(zenodo_select(h, select), auto_unbox = TRUE, null = "null",
                                    digits = NA))
    }, ""),
    stringsAsFactors = FALSE
  )
}

# Identity fields are always kept, whatever `select` says.
zenodo_keep <- c("id", "parent", "pids", "versions", "created", "updated")

# Only the paths in `select` ("metadata.title", "stats", ...) plus the identity fields.
zenodo_select <- function(h, select = NULL) {
  if (is.null(select)) return(h)
  set <- function(x, p, v) {
    if (length(p) == 1) {
      x[[p]] <- v
    } else {
      x[[p[1]]] <- set(x[[p[1]]] %||% list(), p[-1], v)
    }
    x
  }
  out <- h[intersect(zenodo_keep, names(h))]
  for (p in strsplit(select, ".", fixed = TRUE)) {
    v <- tryCatch(h[[p]], error = function(e) NULL) # NULL if the path does not exist
    if (!is.null(v)) out <- set(out, p, v)
  }
  out
}

# Deposit identifier of Zenodo records: the concept DOI (all versions of a deposit), or,
# for records without one (older records, or records with a publisher DOI), the record's
# own DOI.
zenodo_deposit <- function(conceptdoi, doi) {
  ifelse(is.na(conceptdoi) | conceptdoi == "", doi, conceptdoi)
}

# Columns `cols` of all parquet files below `dir` (empty table if none).
zenodo_id_table <- function(dir, cols = c("id", "conceptrecid")) {
  if (!length(list.files(dir, "[.]parquet$", recursive = TRUE))) {
    return(as.data.frame(stats::setNames(rep(list(character()), length(cols)), cols)))
  }
  arrow::open_dataset(dir) |>
    dplyr::select(dplyr::all_of(cols)) |>
    dplyr::collect() |>
    as.data.frame()
}

# Writes all records created in [from, to) as parquet files of at most `chunk` records
# into `dir` and returns the number of records written. Only one chunk is held in memory.
# Zenodo returns at most 10,000 results per search, so larger ranges are halved until
# each piece fits; files are named <from>_<to>_<n>.parquet after their piece.
# `n`: the number of records if already known (saves a count request).
# `extra`: another condition for the search (e.g. on `updated`).
fetch_zenodo_range <- function(cfg, dir, from = NULL, to = NULL, limit = 10000, chunk = 10000,
                               n = NULL, extra = NULL) {
  q <- zenodo_query(cfg, from, to, extra)
  n <- n %||% zenodo_count(cfg, q)
  if (n >= limit) {
    # explicit formats: as.POSIXct() silently drops the time of "YYYY-MM-DDThh:mm:ss"
    t <- function(x, default) {
      as.POSIXct(x %||% default, tz = "UTC", tryFormats = c("%Y-%m-%dT%H:%M:%OS", "%Y-%m-%d"))
    }
    lo <- t(from, "2013-01-01") # Zenodo launch
    hi <- t(to, as.character(Sys.Date() + 1))
    # <= 1: halving a 1 s window gives the same whole-second window again (endless recursion)
    if (difftime(hi, lo, units = "secs") <= 1) stop("10,000+ records within one second: ", q)
    mid <- format(lo + (hi - lo) / 2, "%Y-%m-%dT%H:%M:%S", tz = "UTC")
    return(fetch_zenodo_range(cfg, dir, from, mid, limit, chunk, extra = extra) +
           fetch_zenodo_range(cfg, dir, mid, to, limit, chunk, extra = extra))
  }
  if (n == 0) return(0)
  clean <- function(x) gsub("[^0-9A-Za-z-]", "", x)
  stem <- paste(clean(from %||% "start"), clean(to %||% "now"), sep = "_")
  hits <- list()
  written <- 0
  part <- 0
  flush <- function() {
    if (!length(hits)) return()
    part <<- part + 1
    arrow::write_parquet(zenodo_records(hits, cfg$select),
                         file.path(dir, sprintf("%s_%03d.parquet", stem, part)))
    written <<- written + length(hits)
    hits <<- list()
  }
  res <- zenodo_search(cfg, q, size = zenodo_page_size(), sort = "oldest")
  repeat {
    hits <- c(hits, res$hits$hits)
    message(q, ": ", written + length(hits), " / ", res$hits$total)
    if (length(hits) >= chunk) flush()
    if (is.null(res$links[["next"]])) break
    res <- zenodo_get(res$links[["next"]])
  }
  flush()
  if (written != res$hits$total) {
    stop("Zenodo returned ", written, " of ", res$hits$total, " records for ", q,
         "; nothing was replaced. Run again.", call. = FALSE)
  }
  written
}

# DuckDB connection; no extensions are needed, so nothing is written to ~/.duckdb
# (shared_home, duckdb >= 1.4).
zenodo_duckdb <- function() {
  drv <- if ("shared_home" %in% names(formals(duckdb::duckdb))) {
    duckdb::duckdb(shared_home = FALSE)
  } else {
    duckdb::duckdb()
  }
  DBI::dbConnect(drv)
}

sql_str <- function(x) paste0("'", gsub("'", "''", x, fixed = TRUE), "'")
sql_files <- function(files) sprintf("[%s]", paste(sql_str(files), collapse = ", "))

# Stored parquet files by year folder (named list; empty if none).
year_files <- function(dir) {
  y <- grep("^[0-9]{4}$", list.dirs(dir, recursive = FALSE, full.names = FALSE), value = TRUE)
  f <- lapply(stats::setNames(y, y), function(x) list.files(file.path(dir, x), "[.]parquet$", full.names = TRUE))
  f[lengths(f) > 0]
}

# Stored records per year (for _query.html).
zenodo_year_counts <- function(dir) {
  f <- year_files(dir)
  vapply(f, function(x) nrow(arrow::open_dataset(x)), 1)
}

# SQL condition: `created` in [from, to); NA = open end.
sql_in_interval <- function(from, to) {
  cond <- c(if (!is.na(from)) sprintf("created >= %s", sql_str(from)),
            if (!is.na(to)) sprintf("created < %s", sql_str(to)))
  if (length(cond)) paste(cond, collapse = " AND ") else "TRUE"
}

# Stored records in each interval of `b` (data frame with from, to; NA = open end), counted
# by `created`. This is what the update check compares with Zenodo; nothing is stored.
stored_counts <- function(dir, b) {
  if (!nrow(b)) return(numeric())
  files <- unlist(year_files(dir), use.names = FALSE)
  if (!length(files)) return(rep(0, nrow(b)))
  con <- zenodo_duckdb()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cols <- vapply(seq_len(nrow(b)), function(i) {
    sprintf("count(*) FILTER (WHERE %s) AS b%d", sql_in_interval(b$from[i], b$to[i]), i)
  }, "")
  # ponytail: one FILTER per interval (~725 for weeks since 2013); a range join if that gets slow
  n <- DBI::dbGetQuery(con, sprintf("SELECT %s FROM read_parquet(%s)", paste(cols, collapse = ", "),
                                    sql_files(files)))
  as.numeric(unlist(n[1, ], use.names = FALSE))
}

# Counts the records of each interval of the source on Zenodo (1 request per interval) and
# compares them with the stored records of that interval. Returns the intervals whose counts
# differ (0 rows when nothing changed). Only an addition and a removal with the same number
# of versions in the same interval go unnoticed; the rolling recheck (`cfg$recheck`) also
# counts the next `per_run` finer intervals, and a changed finer interval is returned by
# itself (unless a changed interval already covers it).
# `full`: all intervals are returned. `recheck_last`: last finer interval checked; the new
# one is returned as attribute "recheck_last".
check_zenodo <- function(cfg, dir, full = FALSE, recheck_last = NULL) {
  na_null <- function(x) if (is.na(x)) NULL else x
  count <- function(b) vapply(seq_len(nrow(b)), function(i) {
    zenodo_count(cfg, zenodo_query(cfg, na_null(b$from[i]), na_null(b$to[i])))
  }, 1)
  recheck <- !full && !is.null(cfg$recheck)

  b <- zenodo_buckets(cfg)
  b$old <- stored_counts(dir, b)
  b$new <- count(b)
  changed <- b[b$new != b$old | (full & (b$new > 0 | b$old > 0)), , drop = FALSE]
  if (recheck) {
    fine <- zenodo_buckets(utils::modifyList(cfg, list(interval = cfg$recheck$interval)))
    fine <- recheck_select(fine, cfg$recheck$per_run, recheck_last)
    fine$old <- stored_counts(dir, fine)
    fine$new <- count(fine)
    hit <- fine[fine$new != fine$old, , drop = FALSE]
    covered <- vapply(seq_len(nrow(hit)), function(i) length(zenodo_overlaps(hit[i, ], changed)) > 0, NA)
    changed <- rbind(changed, hit[!covered, , drop = FALSE])
  }
  changed <- changed[order(changed$from, na.last = FALSE), c("bucket", "from", "to", "old", "new"), drop = FALSE]
  rownames(changed) <- NULL
  message(sprintf("%d intervals checked (%s%s), %d records on Zenodo, %d to download%s",
                  nrow(b), cfg$interval,
                  if (full) ", full re-download" else if (recheck) {
                    sprintf("; recheck of %d %s(s) %s to %s", nrow(fine), cfg$recheck$interval,
                            fine$bucket[1], fine$bucket[nrow(fine)])
                  } else "",
                  sum(b$new), nrow(changed),
                  if (nrow(changed)) paste0(": ", toString(sprintf("%s (%d -> %d)",
                    changed$bucket, changed$old, changed$new))) else ""))
  attr(changed, "recheck_last") <- if (recheck) fine$bucket[nrow(fine)] else recheck_last
  changed
}

# Downloads the intervals the check found changed and merges them into the year folders of
# `dir`. Consecutive changed intervals with fewer than 10,000 records together are downloaded
# in one query; the counts from the check are reused, so no extra count requests are needed.
# Everything is downloaded into a temporary folder first; only then are the years replaced.
# `full`: all stored records are replaced. Returns the last change (added / removed deposits
# and records), or NULL if nothing changed.
fetch_zenodo <- function(cfg, changed, dir, full = FALSE, limit = 10000) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  if (!nrow(changed)) return(NULL)
  ids <- c("id", "conceptdoi", "doi")
  before <- zenodo_id_table(dir, ids)
  tmp_root <- paste0(dir, ".tmp")
  unlink(tmp_root, recursive = TRUE)
  on.exit(unlink(tmp_root, recursive = TRUE))
  na_null <- function(x) if (is.na(x)) NULL else x

  # runs of consecutive intervals to download together
  get <- changed[changed$new > 0, , drop = FALSE]
  run <- integer(nrow(get))
  for (i in seq_len(nrow(get))) {
    joins <- i > 1 && identical(get$to[i - 1], get$from[i]) &&
      sum(get$new[run == run[i - 1]]) + get$new[i] < limit
    run[i] <- if (i == 1) 1L else if (joins) run[i - 1] else run[i - 1] + 1L
  }
  for (r in unique(run)) {
    g <- get[run == r, ]
    d <- file.path(tmp_root, paste0("run", r))
    dir.create(d, recursive = TRUE)
    fetch_zenodo_range(cfg, d, na_null(g$from[1]), na_null(g$to[nrow(g)]), n = sum(g$new))
  }
  drop <- if (full) "TRUE" else {
    paste0("(", vapply(seq_len(nrow(changed)), function(i) sql_in_interval(changed$from[i], changed$to[i]), ""),
           ")", collapse = " OR ")
  }
  zenodo_merge(dir, tmp_root, drop, if (!full) changed)

  after <- zenodo_id_table(dir, ids)
  if (anyDuplicated(after$id)) stop("Duplicate records in ", dir, "; run with `full = TRUE`.", call. = FALSE)
  n <- function(a, b) length(setdiff(unique(a), unique(b)))
  dep_before <- zenodo_deposit(before$conceptdoi, before$doi)
  dep_after <- zenodo_deposit(after$conceptdoi, after$doi)
  list(
    date = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    added_deposits = n(dep_after, dep_before),
    removed_deposits = n(dep_before, dep_after),
    added_records = n(after$id, before$id),
    removed_records = n(before$id, after$id)
  )
}

# Merges the records downloaded below `tmp_root` into the year folders of `dir`: each year is
# rewritten with its stored records except those matching `drop` (SQL), plus the downloaded
# records of that year. Years touched: those of the downloaded records, and the stored years
# overlapping `intervals` (data frame with from, to), or all stored years if `intervals` is
# NULL and `drop` is "TRUE". Each year folder is replaced atomically; a run that stops between
# two years leaves counts that differ from Zenodo, which the next check repairs.
zenodo_merge <- function(dir, tmp_root, drop, intervals = NULL) {
  old <- year_files(dir)
  new <- list.files(tmp_root, "[.]parquet$", recursive = TRUE, full.names = TRUE)
  new <- new[!startsWith(new, file.path(tmp_root, "merged"))]
  con <- zenodo_duckdb()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  new_years <- if (length(new)) {
    DBI::dbGetQuery(con, sprintf("SELECT DISTINCT left(created, 4) AS y FROM read_parquet(%s)", sql_files(new)))$y
  } else character()
  touched <- if (!is.null(intervals)) {
    names(old)[vapply(names(old), function(y) {
      lo <- sprintf("%s-01-01", y)
      hi <- sprintf("%d-01-01", as.integer(y) + 1L)
      any((is.na(intervals$to) | intervals$to > lo) & (is.na(intervals$from) | intervals$from < hi))
    }, NA)]
  } else if (identical(drop, "TRUE")) names(old) else character()
  years <- sort(union(touched, new_years))
  out_root <- file.path(tmp_root, "merged")
  rows <- integer()
  for (y in years) {
    parts <- c(
      if (!is.null(old[[y]])) sprintf("SELECT * FROM read_parquet(%s, union_by_name = true) WHERE NOT (%s)",
                                      sql_files(old[[y]]), drop),
      if (y %in% new_years) sprintf("SELECT * FROM read_parquet(%s, union_by_name = true) WHERE left(created, 4) = %s",
                                    sql_files(new), sql_str(y))
    )
    out <- file.path(out_root, y, "data_001.parquet")
    dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
    rows[y] <- DBI::dbExecute(con, sprintf(
      "COPY (SELECT * FROM (%s) ORDER BY created) TO %s (FORMAT parquet, COMPRESSION zstd)",
      paste(parts, collapse = " UNION ALL BY NAME "), sql_str(out)))
  }
  for (y in years) {
    unlink(file.path(dir, y), recursive = TRUE)
    if (rows[[y]] > 0) file.rename(file.path(out_root, y), file.path(dir, y))
  }
  invisible(rows)
}

# Metadata edits do not change the counts: records of the source updated since `since`
# replace their stored copies (merged into the year of their `created`). More than 10,000
# edits are split by creation date like any download. Returns the number of records replaced.
zenodo_upsert_updated <- function(cfg, dir, since) {
  tmp_root <- paste0(dir, ".upd")
  unlink(tmp_root, recursive = TRUE)
  on.exit(unlink(tmp_root, recursive = TRUE))
  d <- file.path(tmp_root, "run1")
  dir.create(d, recursive = TRUE)
  n <- fetch_zenodo_range(cfg, d, cfg$from, cfg$to, extra = sprintf('updated:["%s" TO *]', since))
  if (!n) return(0)
  new <- list.files(d, "[.]parquet$", full.names = TRUE)
  zenodo_merge(dir, tmp_root, sprintf("id IN (SELECT id FROM read_parquet(%s))", sql_files(new)))
  message(n, " record(s) edited since ", since, " replaced")
  n
}

# Downloads made with the earlier layout (one folder per check interval, e.g. 2024-03/,
# 2024-W05/, all/) are rewritten as year folders, locally. Year folders (also those of the
# earlier interval "year") are already in the current layout.
zenodo_convert_layout <- function(dir) {
  sub <- list.dirs(dir, recursive = FALSE, full.names = FALSE)
  old <- sub[!grepl("^[0-9]{4}$", sub)]
  if (!length(old)) return(invisible(FALSE))
  files <- list.files(file.path(dir, sub), "[.]parquet$", full.names = TRUE)
  tmp_root <- paste0(dir, ".convert")
  unlink(tmp_root, recursive = TRUE)
  on.exit(unlink(tmp_root, recursive = TRUE))
  d <- file.path(tmp_root, "run1")
  dir.create(d, recursive = TRUE)
  file.copy(files, file.path(d, paste0(seq_along(files), ".parquet")))
  zenodo_merge(dir, tmp_root, "TRUE") # no year folders yet: writes them from the copies
  unlink(file.path(dir, old), recursive = TRUE)
  message("Converted ", dir, " to one folder per year of `created`.")
  invisible(TRUE)
}
