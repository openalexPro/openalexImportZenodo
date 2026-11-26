# The raw store: raw/<name>/<interval>/*.parquet, one row per record (version), with the
# ID columns and the full hit as JSON. Copied from zenodo-openalex-collection
# (fetch_zenodo_range.R, fetch_zenodo.R, check_zenodo.R, zenodo_records.R,
# zenodo_bucket_counts.R, zenodo_id_table.R, zenodo_deposit.R) and adapted:
# InvenioRDM fields, `json` column, no files outside `dir`, state returned instead of written.

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

# Stored records per interval: rows in each interval folder of `dir`, named by interval.
# This is what the update check compares with Zenodo; no counts are stored anywhere.
zenodo_bucket_counts <- function(dir) {
  b <- list.dirs(dir, recursive = FALSE, full.names = FALSE)
  b <- grep("^([0-9]{4}(-W[0-9]{2}|-[0-9]{2}|-Q[1-4])?|all)$", b, value = TRUE)
  vapply(stats::setNames(b, b), function(x) nrow(arrow::open_dataset(file.path(dir, x))), 1)
}

# Writes all records created in [from, to) as parquet files of at most `chunk` records
# into `dir` and returns the number of records written. Only one chunk is held in memory.
# Zenodo returns at most 10,000 results per search, so larger ranges are halved until
# each piece fits; files are named <from>_<to>_<n>.parquet after their piece.
# `n`: the number of records if already known (saves a count request).
fetch_zenodo_range <- function(cfg, dir, from = NULL, to = NULL, limit = 10000, chunk = 10000,
                               n = NULL) {
  q <- zenodo_query(cfg, from, to)
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
    return(fetch_zenodo_range(cfg, dir, from, mid, limit, chunk) +
           fetch_zenodo_range(cfg, dir, mid, to, limit, chunk))
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

# Counts the records of each interval of the source on Zenodo (1 request per interval) and
# compares them with the stored interval folders. Returns the intervals whose counts differ
# (0 rows when nothing changed). Only an addition and a removal with the same number of
# versions in the same interval go unnoticed; the rolling recheck (`cfg$recheck`) counts
# the next `per_run` finer intervals each run to catch those.
# `full`: all intervals are returned. `recheck_last`: last finer interval checked; the new
# one is returned as attribute "recheck_last".
# Stored folders of other intervals (changed `interval`, `from` or `to`) are returned
# with new = 0, so the download removes them.
check_zenodo <- function(cfg, dir, full = FALSE, recheck_last = NULL) {
  na_null <- function(x) if (is.na(x)) NULL else x
  count <- function(b) vapply(seq_len(nrow(b)), function(i) {
    zenodo_count(cfg, zenodo_query(cfg, na_null(b$from[i]), na_null(b$to[i])))
  }, 1)
  recheck <- !full && !is.null(cfg$recheck)

  b <- zenodo_buckets(cfg)
  old <- zenodo_bucket_counts(dir)
  b$old <- unname(old[b$bucket])
  b$old[is.na(b$old)] <- 0
  b$new <- count(b)
  hit <- character()
  if (recheck) {
    fine <- zenodo_buckets(utils::modifyList(cfg, list(interval = cfg$recheck$interval)))
    fine <- recheck_select(fine, cfg$recheck$per_run, recheck_last)
    fine$new <- count(fine)
    created <- zenodo_id_table(dir, "created")$created
    cached <- table(zenodo_bucket_label(created, cfg$recheck$interval))
    fine$old <- as.vector(cached[fine$bucket])
    fine$old[is.na(fine$old)] <- 0
    hit <- zenodo_overlaps(fine[fine$new != fine$old, ], b)
  }
  gone <- setdiff(names(old), b$bucket)
  if (length(gone)) {
    b <- rbind(b, data.frame(bucket = gone, from = NA, to = NA, old = unname(old[gone]), new = 0))
  }
  sel <- b$new != b$old | b$bucket %in% hit | (full & (b$new > 0 | b$old > 0))
  changed <- b[sel, c("bucket", "from", "to", "old", "new")]
  rownames(changed) <- NULL
  message(sprintf("%d intervals checked (%s%s), %d records on Zenodo, %d to download%s",
                  nrow(b) - length(gone), cfg$interval,
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

# Downloads the intervals the check found changed into `dir`/<interval>/.
# Consecutive changed intervals with fewer than 10,000 records together are downloaded in
# one query and split into their folders by `created`; the counts from the check are
# reused, so no extra count requests are needed. Everything is downloaded into a temporary
# folder first and replaces the old interval folders only when complete, so an interrupted
# download leaves the old data intact. Intervals now empty are removed.
# Returns the last change (added / removed deposits and records), or NULL if nothing changed.
fetch_zenodo <- function(cfg, changed, dir, limit = 10000) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  ids <- c("id", "conceptdoi", "doi")
  before <- zenodo_id_table(dir, ids)
  tmp_root <- paste0(dir, ".tmp")
  unlink(tmp_root, recursive = TRUE)
  na_null <- function(x) if (is.na(x)) NULL else x

  # runs of consecutive intervals to download together
  get <- changed[changed$new > 0, ]
  run <- integer(nrow(get))
  for (i in seq_len(nrow(get))) {
    joins <- i > 1 && identical(get$to[i - 1], get$from[i]) &&
      sum(get$new[run == run[i - 1]]) + get$new[i] < limit
    run[i] <- if (i == 1) 1L else if (joins) run[i - 1] else run[i - 1] + 1L
  }
  for (r in unique(run)) {
    g <- get[run == r, ]
    raw <- file.path(tmp_root, paste0(".run", r))
    dir.create(raw, recursive = TRUE)
    fetch_zenodo_range(cfg, raw, na_null(g$from[1]), na_null(g$to[nrow(g)]), n = sum(g$new))
    if (nrow(g) == 1) {
      file.rename(raw, file.path(tmp_root, g$bucket))
      next
    }
    # several intervals (< 10,000 records together): split by created
    d <- dplyr::collect(arrow::open_dataset(raw))
    lab <- zenodo_bucket_label(d$created, cfg$interval)
    clean <- function(x, open) if (is.na(x)) open else gsub("[^0-9A-Za-z-]", "", x)
    for (i in seq_len(nrow(g))) {
      b <- g$bucket[i]
      dir.create(file.path(tmp_root, b))
      stem <- paste(clean(g$from[i], "start"), clean(g$to[i], "now"), sep = "_")
      arrow::write_parquet(d[lab == b, ], file.path(tmp_root, b, paste0(stem, "_001.parquet")))
    }
    unlink(raw, recursive = TRUE)
  }
  for (b in changed$bucket) {
    unlink(file.path(dir, b), recursive = TRUE)
    if (dir.exists(file.path(tmp_root, b))) file.rename(file.path(tmp_root, b), file.path(dir, b))
  }
  unlink(tmp_root, recursive = TRUE)

  after <- zenodo_id_table(dir, ids)
  if (anyDuplicated(after$id)) stop("Duplicate records in ", dir, "; run with `full = TRUE`.", call. = FALSE)
  if (!nrow(changed)) return(NULL)
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

# Metadata edits do not change the counts: records of the source updated since `since`
# replace their stored copies (in the interval folder of their `created`). Each touched
# folder is rewritten as one file, atomically. Returns the number of records replaced.
zenodo_upsert_updated <- function(cfg, dir, since) {
  q <- paste0(zenodo_query(cfg, cfg$from, cfg$to), sprintf(' AND updated:["%s" TO *]', since))
  res <- zenodo_search(cfg, q, size = zenodo_page_size(), sort = "oldest")
  if (res$hits$total >= 10000) {
    stop("10,000+ records edited since ", since, "; run with `full = TRUE`.", call. = FALSE)
  }
  hits <- res$hits$hits
  while (!is.null(res$links[["next"]])) {
    res <- zenodo_get(res$links[["next"]])
    hits <- c(hits, res$hits$hits)
  }
  if (!length(hits)) return(0)
  new <- zenodo_records(hits, cfg$select)
  lab <- zenodo_bucket_label(new$created, cfg$interval)
  for (b in unique(lab)) {
    folder <- file.path(dir, b)
    nb <- new[lab == b, , drop = FALSE]
    old <- if (dir.exists(folder)) as.data.frame(dplyr::collect(arrow::open_dataset(folder))) else nb[0, ]
    old <- old[!old$id %in% nb$id, names(nb), drop = FALSE]
    tmp <- paste0(folder, ".tmp")
    unlink(tmp, recursive = TRUE)
    dir.create(tmp, recursive = TRUE)
    arrow::write_parquet(rbind(old, nb), file.path(tmp, "updated_001.parquet"))
    unlink(folder, recursive = TRUE)
    file.rename(tmp, folder)
  }
  message(length(hits), " record(s) edited since ", since, " replaced")
  length(hits)
}
