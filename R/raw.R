# The raw store: raw/<name>/<part>/*.parquet, one row per record (version), with the ID
# columns and the full hit as JSON. A part is a year of `created` (or a quarter / month,
# `parquet_split`). Storage does not depend on the check interval: the check counts stored
# records per interval by `created`, so any interval can be checked at any time; changed
# intervals are downloaded and merged into their parts.
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

# "2 h 05 min", "4 min", "30 s"
duration <- function(secs) {
  secs <- round(secs)
  if (secs < 60) return(paste(secs, "s"))
  m <- round(secs / 60)
  if (m < 60) paste(m, "min") else sprintf("%d h %02d min", m %/% 60, m %% 60)
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

# ---- parquet_split ---------------------------------------------------------------------
# "none", "year", "quarter", "month", or a number of rows per file (approximate).
split_periods <- c("year", "quarter", "month")

check_split <- function(x) {
  ok <- is.null(x) || (is.character(x) && length(x) == 1 && x %in% c("none", split_periods)) ||
    (is.numeric(x) && length(x) == 1 && !is.na(x) && x >= 1 && x == round(x))
  if (!ok) {
    stop("`parquet_split` must be \"none\", \"year\", \"quarter\", \"month\" or a number of ",
         "works per file.", call. = FALSE)
  }
  x
}

# Period of the raw/ folders: the split period, else year.
raw_period <- function(split) if (is.character(split) && split %in% split_periods) split else "year"

# SQL: part label of a `created` column for a period ("2024", "2024-Q1", "2024-03").
sql_label <- function(period, col = "created") {
  switch(period,
    year = sprintf("left(%s, 4)", col),
    month = sprintf("left(%s, 7)", col),
    quarter = sprintf("left(%1$s, 4) || '-Q' || CAST((CAST(substr(%1$s, 6, 2) AS INTEGER) - 1) // 3 + 1 AS VARCHAR)", col)
  )
}

label_regex <- function(period) {
  c(year = "^[0-9]{4}$", quarter = "^[0-9]{4}-Q[1-4]$", month = "^[0-9]{4}-[0-9]{2}$")[[period]]
}

# [from, to) of part labels.
label_range <- function(labels, period) {
  from <- zenodo_bucket_start(labels)
  step <- c(year = "year", quarter = "3 months", month = "month")[[period]]
  to <- vapply(from, function(f) as.character(seq(as.Date(f), by = step, length.out = 2)[2]), "")
  data.frame(from = from, to = unname(to))
}

# COPY options for files of about `n` rows (row groups of <= 122,880 rows; DuckDB rounds them
# to its vector size, so files are approximately, not exactly, `n` rows).
sql_rows_per_file <- function(n) {
  if (!is.numeric(n)) return("")
  k <- ceiling(n / 122880)
  sprintf(", ROW_GROUP_SIZE %d, ROW_GROUPS_PER_FILE %d", as.integer(ceiling(n / k)), as.integer(k))
}

# ---- stored parts ------------------------------------------------------------------------
# Part folders of `dir` in the layout of `period`.
stored_parts <- function(dir, period) {
  grep(label_regex(period), list.dirs(dir, recursive = FALSE, full.names = FALSE), value = TRUE)
}

stored_files <- function(dir) list.files(dir, "[.]parquet$", recursive = TRUE, full.names = TRUE)

# Stored records per part folder (for _query.html).
zenodo_part_counts <- function(dir) {
  p <- list.dirs(dir, recursive = FALSE, full.names = FALSE)
  f <- lapply(stats::setNames(p, p), function(x) list.files(file.path(dir, x), "[.]parquet$", full.names = TRUE))
  f <- f[lengths(f) > 0]
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
  files <- stored_files(dir)
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
  count <- function(b, what) {
    message(sprintf("Counting records on Zenodo by %s: %d intervals (~%s)", what, nrow(b),
                    duration(nrow(b) * 2.2)))
    vapply(seq_len(nrow(b)), function(i) {
      n <- zenodo_count(cfg, zenodo_query(cfg, na_null(b$from[i]), na_null(b$to[i])))
      message(sprintf("  [%d/%d] %s: %d", i, nrow(b), b$bucket[i], n))
      n
    }, 1)
  }
  recheck <- !full && !is.null(cfg$recheck)

  b <- zenodo_buckets(cfg)
  b$old <- stored_counts(dir, b)
  b$new <- count(b, cfg$interval)
  changed <- b[b$new != b$old | (full & (b$new > 0 | b$old > 0)), , drop = FALSE]
  if (recheck) {
    fine <- zenodo_buckets(utils::modifyList(cfg, list(interval = cfg$recheck$interval)))
    fine <- recheck_select(fine, cfg$recheck$per_run, recheck_last)
    fine$old <- stored_counts(dir, fine)
    fine$new <- count(fine, paste(cfg$recheck$interval, "(rolling recheck)"))
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

# Downloads the intervals the check found changed and merges them into the part folders of
# `dir`. Consecutive changed intervals with fewer than 10,000 records together are downloaded
# in one query (a run); the counts from the check are reused, so no extra count requests are
# needed. Each run is merged as soon as it is downloaded, so an interrupted download keeps
# what it has and the next check downloads only the rest. Intervals now empty on Zenodo (and,
# with `full`, all records outside the downloaded intervals) are dropped at the end.
# Returns the last change (added / removed deposits and records), or NULL if nothing changed.
fetch_zenodo <- function(cfg, changed, dir, full = FALSE, split = "none", limit = 10000) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  if (!nrow(changed)) return(NULL)
  ids <- c("id", "conceptdoi", "doi")
  before <- zenodo_id_table(dir, ids)
  tmp_root <- paste0(dir, ".tmp")
  unlink(tmp_root, recursive = TRUE)
  on.exit(unlink(tmp_root, recursive = TRUE))
  na_null <- function(x) if (is.na(x)) NULL else x
  any_of <- function(b) {
    paste0("(", vapply(seq_len(nrow(b)), function(i) sql_in_interval(b$from[i], b$to[i]), ""),
           ")", collapse = " OR ")
  }

  # runs of consecutive intervals to download together
  get <- changed[changed$new > 0, , drop = FALSE]
  run <- integer(nrow(get))
  for (i in seq_len(nrow(get))) {
    joins <- i > 1 && identical(get$to[i - 1], get$from[i]) &&
      sum(get$new[run == run[i - 1]]) + get$new[i] < limit
    run[i] <- if (i == 1) 1L else if (joins) run[i - 1] else run[i - 1] + 1L
  }
  pages <- function(n) ceiling(n / zenodo_page_size())
  if (nrow(get)) {
    message(sprintf("Downloading %d records in %d run(s) (~%s); each run is kept when done",
                    sum(get$new), max(run), duration(sum(pages(get$new)) * 2.2)))
  }
  t0 <- Sys.time()
  for (r in unique(run)) {
    g <- get[run == r, , drop = FALSE]
    message(sprintf("Run %d/%d: %s, %d records", r, max(run),
                    paste(unique(g$bucket[c(1, nrow(g))]), collapse = " to "), sum(g$new)))
    d <- file.path(tmp_root, paste0("run", r))
    dir.create(file.path(d, "dl"), recursive = TRUE)
    fetch_zenodo_range(cfg, file.path(d, "dl"), na_null(g$from[1]), na_null(g$to[nrow(g)]), n = sum(g$new))
    zenodo_merge(dir, d, any_of(g), g, split)
    unlink(d, recursive = TRUE)
    left <- sum(get$new[run > r])
    if (left) {
      done <- sum(get$new[run <= r])
      el <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
      message(sprintf("Run %d/%d kept; %d records left (~%s)", r, max(run), left, duration(el / done * left)))
    }
  }
  gone <- changed[changed$new == 0, , drop = FALSE]
  drop <- if (full) {
    if (nrow(get)) sprintf("NOT (%s)", any_of(get)) else "TRUE"
  } else if (nrow(gone)) any_of(gone)
  if (!is.null(drop)) {
    everything <- data.frame(from = NA_character_, to = NA_character_)
    zenodo_merge(dir, file.path(tmp_root, "drop"), drop, if (full) everything else gone, split)
  }

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

# Merges the records downloaded below `tmp_root` into the part folders of `dir`: each part is
# rewritten with its stored records except those matching `drop` (SQL), plus the downloaded
# records of that part. Parts touched: those of the downloaded records, and the stored parts
# overlapping `intervals` (data frame with from, to), or all stored parts if `intervals` is
# NULL and `drop` is "TRUE". One pass over the data (COPY ... PARTITION_BY); each part folder
# is then replaced; a run that stops between two parts leaves counts that differ from Zenodo,
# which the next check repairs.
zenodo_merge <- function(dir, tmp_root, drop, intervals = NULL, split = "none") {
  period <- raw_period(split)
  label <- sql_label(period)
  old <- stored_parts(dir, period)
  new <- list.files(tmp_root, "[.]parquet$", recursive = TRUE, full.names = TRUE)
  out_root <- file.path(tmp_root, "merged")
  new <- new[!startsWith(new, out_root)]
  dir.create(tmp_root, recursive = TRUE, showWarnings = FALSE)
  con <- zenodo_duckdb()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  new_parts <- if (length(new)) {
    DBI::dbGetQuery(con, sprintf("SELECT DISTINCT %s AS p FROM read_parquet(%s)", label, sql_files(new)))$p
  } else character()
  touched <- if (!is.null(intervals) && length(old)) {
    r <- label_range(old, period)
    old[vapply(seq_along(old), function(i) {
      any((is.na(intervals$to) | intervals$to > r$from[i]) & (is.na(intervals$from) | intervals$from < r$to[i]))
    }, NA)]
  } else if (identical(drop, "TRUE")) old else character()
  parts <- sort(union(touched, new_parts))
  if (!length(parts)) return(invisible(character()))
  old_files <- unlist(lapply(file.path(dir, touched), list.files, pattern = "[.]parquet$", full.names = TRUE))
  sel <- c(
    if (length(old_files)) sprintf("SELECT * FROM read_parquet(%s, union_by_name = true) WHERE NOT (%s)",
                                   sql_files(old_files), drop),
    if (length(new)) sprintf("SELECT * FROM read_parquet(%s, union_by_name = true)", sql_files(new))
  )
  DBI::dbExecute(con, sprintf(
    "COPY (SELECT *, %s AS zenodo_part FROM (%s) ORDER BY created) TO %s
     (FORMAT parquet, COMPRESSION zstd, PARTITION_BY (zenodo_part), WRITE_PARTITION_COLUMNS false%s)",
    label, paste(sel, collapse = " UNION ALL BY NAME "), sql_str(out_root), sql_rows_per_file(split)))
  for (p in parts) {
    unlink(file.path(dir, p), recursive = TRUE)
    src <- file.path(out_root, paste0("zenodo_part=", p))
    if (dir.exists(src)) file.rename(src, file.path(dir, p))
  }
  invisible(parts)
}

# Metadata edits do not change the counts: records of the source updated since `since`
# replace their stored copies (merged into the year of their `created`). More than 10,000
# edits are split by creation date like any download. Returns the number of records replaced.
zenodo_upsert_updated <- function(cfg, dir, since, split = "none") {
  tmp_root <- paste0(dir, ".upd")
  unlink(tmp_root, recursive = TRUE)
  on.exit(unlink(tmp_root, recursive = TRUE))
  d <- file.path(tmp_root, "run1")
  dir.create(d, recursive = TRUE)
  n <- fetch_zenodo_range(cfg, d, cfg$from, cfg$to, extra = sprintf('updated:["%s" TO *]', since))
  if (!n) return(0)
  new <- list.files(d, "[.]parquet$", full.names = TRUE)
  zenodo_merge(dir, tmp_root, sprintf("id IN (SELECT id FROM read_parquet(%s))", sql_files(new)), split = split)
  message(n, " record(s) edited since ", since, " replaced")
  n
}

# Downloads stored in another layout (an earlier one with one folder per check interval, e.g.
# 2024-W05/, all/, or another `parquet_split` period) are rewritten in the layout of `split`,
# locally.
zenodo_convert_layout <- function(dir, split = "none") {
  period <- raw_period(split)
  sub <- list.dirs(dir, recursive = FALSE, full.names = FALSE)
  other <- sub[!grepl(label_regex(period), sub)]
  if (!length(other)) return(invisible(FALSE))
  files <- list.files(file.path(dir, sub), "[.]parquet$", full.names = TRUE)
  tmp_root <- paste0(dir, ".convert")
  unlink(tmp_root, recursive = TRUE)
  on.exit(unlink(tmp_root, recursive = TRUE))
  d <- file.path(tmp_root, "run1")
  dir.create(d, recursive = TRUE)
  file.copy(files, file.path(d, paste0(seq_along(files), ".parquet")))
  zenodo_merge(dir, tmp_root, "TRUE", split = split) # rewrites the parts of `period` from the copies
  unlink(file.path(dir, other), recursive = TRUE)
  message("Converted ", dir, " to one folder per ", period, " of `created`.")
  invisible(TRUE)
}
