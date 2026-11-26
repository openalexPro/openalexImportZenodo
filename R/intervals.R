# Copied unchanged from zenodo-openalex-collection (R/zenodo_intervals.R, zenodo_buckets.R,
# zenodo_bucket_label.R, zenodo_bucket_start.R, zenodo_iso_week.R, zenodo_overlaps.R,
# recheck_select.R). `cfg` is the source spec from zenodo_source().

# Interval sizes for the check and the download (config field `interval`), finest first.
zenodo_intervals <- c("week", "month", "quarter", "year", "all")

# The entry's interval; missing or ~ = year.
zenodo_interval <- function(cfg) cfg$interval %||% "year"

# Intervals [from, to) covering the config's range, in the size given by `interval`
# (week, month, quarter, year or all). NA = open end (from: before Zenodo's launch in 2013,
# to: until now).
zenodo_buckets <- function(cfg) {
  interval <- zenodo_interval(cfg)
  if (interval == "all") {
    return(data.frame(bucket = "all", from = cfg$from %||% NA_character_,
                      to = cfg$to %||% NA_character_))
  }
  day <- \(x) as.Date(substr(x, 1, 10))
  start <- day(cfg$from %||% "2013-01-01")
  end <- day(cfg$to %||% as.character(Sys.Date() + 1))
  first <- switch(interval,
    week = as.character(start - (as.integer(format(start, "%u")) - 1)),
    month = format(start, "%Y-%m-01"),
    quarter = sprintf("%s-%02d-01", format(start, "%Y"),
                      (as.integer(format(start, "%m")) - 1) %/% 3 * 3 + 1),
    year = format(start, "%Y-01-01")
  )
  step <- c(week = "week", month = "month", quarter = "3 months", year = "year")[[interval]]
  b <- seq(as.Date(first), end, by = step)
  b <- b[b < end]
  data.frame(
    bucket = zenodo_bucket_label(as.character(b), interval),
    from = c(cfg$from %||% NA_character_, as.character(b[-1])),
    to = c(as.character(b[-1]), cfg$to %||% NA_character_)
  )
}

# Interval label of Zenodo `created` timestamps (or dates):
# "2024-W09" (ISO week), "2024-03", "2024-Q1", "2024", "all".
zenodo_bucket_label <- function(x, interval = "month") {
  switch(interval,
    week = format(as.Date(substr(x, 1, 10)), "%G-W%V"),
    month = substr(x, 1, 7),
    quarter = paste0(substr(x, 1, 4), "-Q", (as.integer(substr(x, 6, 7)) - 1) %/% 3 + 1),
    year = substr(x, 1, 4),
    all = rep("all", length(x))
  )
}

# First day of an interval label ("2024-W09", "2024-03", "2024-Q2", "2024"); NA for "all".
zenodo_bucket_start <- function(label) {
  out <- rep(NA_character_, length(label))
  w <- grepl("^[0-9]{4}-W[0-9]{2}$", label)
  m <- grepl("^[0-9]{4}-[0-9]{2}$", label)
  q <- grepl("^[0-9]{4}-Q[1-4]$", label)
  y <- grepl("^[0-9]{4}$", label)
  out[w] <- as.character(zenodo_iso_week_monday(substr(label[w], 1, 4), substr(label[w], 7, 8)))
  out[m] <- paste0(label[m], "-01")
  out[q] <- sprintf("%s-%02d-01", substr(label[q], 1, 4), (as.integer(substr(label[q], 7, 7)) - 1) * 3 + 1)
  out[y] <- paste0(label[y], "-01-01")
  out
}

# Monday of ISO week `week` of ISO year `year` (Dates).
zenodo_iso_week_monday <- function(year, week) {
  jan4 <- as.Date(sprintf("%d-01-04", as.integer(year)))
  jan4 - (as.integer(format(jan4, "%u")) - 1) + 7 * (as.integer(week) - 1)
}

# Labels of the intervals in `storage` (data frame with bucket, from, to; NA = open end)
# that overlap any of the intervals in `fine`. A fine interval that spans two storage
# intervals (e.g. a week across a month end) marks both.
zenodo_overlaps <- function(fine, storage) {
  lo <- \(x) ifelse(is.na(x), "0000-01-01", substr(x, 1, 10))
  hi <- \(x) ifelse(is.na(x), "9999-12-31", substr(x, 1, 10))
  hit <- vapply(seq_len(nrow(storage)), \(i) {
    any(lo(fine$from) < hi(storage$to[i]) & hi(fine$to) > lo(storage$from[i]))
  }, NA)
  storage$bucket[hit]
}

# The finer intervals to recheck in this run: all of them (`every`), or, for a rolling
# recheck (`per_run`), the next `per_run` after the last one checked (`last`, kept with
# the data), in chronological order, starting again at the beginning after the end.
recheck_select <- function(fine, per_run = NULL, last = NULL) {
  if (is.null(per_run) || per_run >= nrow(fine)) return(fine)
  pos <- match(last %||% NA_character_, fine$bucket)
  if (is.na(pos)) pos <- 0
  idx <- (pos + seq_len(per_run) - 1) %% nrow(fine) + 1
  fine[idx, , drop = FALSE]
}

