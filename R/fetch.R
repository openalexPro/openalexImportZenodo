#' Download or update Zenodo records as a works corpus
#'
#' Downloads all records (all versions) of a Zenodo community, a Zenodo search or a list
#' of records into `<project_folder>/raw/<name>/`, one folder per year of the records'
#' creation date, and then builds the works corpus and the link table from them (see
#' [zenodo_build()]), so that `<project_folder>/corpus/` can be used right away, e.g. with
#' `openalexAPI::serve_corpus()`. Called again, it downloads only what changed:
#'
#' - **added or removed records**: the records per `interval` are counted on Zenodo (one
#'   request per interval) and compared with the stored records of that interval (counted by
#'   creation date); intervals whose counts differ are downloaded again and merged in. The
#'   interval can be different in every call (weekly for an active source, monthly for a big
#'   one, ...). With `recheck_interval` / `recheck_per_run`, each run also counts the next
#'   `recheck_per_run` finer intervals, which catches an addition and a removal that cancel
#'   out within one interval.
#' - **edited records** (counts unchanged): records updated on Zenodo since the last run
#'   replace their stored copies.
#'
#' Zenodo allows 30 search requests per minute; requests are spaced at 2.2 s. With a Zenodo
#' token (environment variable or keyring entry `API_zenodo_ro`, no scopes needed) a page
#' has 100 instead of 25 records. Zenodo returns at most 10,000 records per search; larger
#' intervals are split automatically.
#'
#' The arguments are stored in `raw/<name>/_query.json` together with the last run; the
#' same is in `raw/<name>/_query.html`, readable, with a link to the search on zenodo.org.
#' A later call for the same `name` must ask for the same records (`community` / `query` /
#' `ids`, `communities`, `resource_type`, `from`, `to`, `select`), or use `full = TRUE`.
#' The check settings (`interval`, recheck) and `versions` / `stats` can change in every
#' call; left `NULL`, they are those of the last call. [zenodo_update()] reruns a source from
#' its stored arguments.
#'
#' @param community Zenodo community (the `<id>` in `zenodo.org/communities/<id>`).
#' @param query Zenodo search string (as on zenodo.org, e.g. `"bats AND switzerland"`).
#' @param ids Zenodo record IDs, concept record IDs or DOIs. Each is resolved to its
#'   deposit, and all versions of these deposits are downloaded.
#' @param communities Only records in these communities (with `query` or `ids`).
#' @param resource_type Only records of these Zenodo resource types (e.g. `"dataset"`,
#'   `"publication"`).
#' @param from,to Only records created in `[from, to)` (`"YYYY-MM-DD"`); `NULL` = open.
#' @param interval Interval of the creation date for the update check: `"week"`,
#'   `"month"`, `"quarter"`, `"year"` or `"all"`; `NULL`: as last time (first time
#'   `"year"`). Finer intervals cost more requests per check (2013 to now: ~14 by year,
#'   ~167 by month, ~725 by week) and re-download less per change.
#' @param recheck_interval,recheck_per_run Rolling recheck: each run counts the next
#'   `recheck_per_run` intervals of size `recheck_interval` (finer than `interval`);
#'   `NULL`: as last time; `recheck_per_run = 0` switches it off.
#' @param select `NULL` (default) to store each record completely, or the parts to store
#'   (`"metadata.title"`, `"metadata.related_identifiers"`, `"stats"`, ...); identity fields
#'   are always stored. Zenodo always sends complete records, so this saves disk space,
#'   not download time.
#' @param project_folder Project folder.
#' @param name Name of the source within the project folder.
#' @param full Download everything again; also needed to change the arguments of `name`.
#' @param versions,stats,parquet_split As in [zenodo_build()]; `NULL`: as last time (first
#'   time `"latest"`, `FALSE`, `"none"`). `parquet_split` also sets how `raw/` is split: one
#'   folder per period (`"year"`, `"quarter"`, `"month"`) of each record's creation date, else
#'   one folder per year (with files of about that many records for a number).
#'
#' @return Invisibly, the paths of the corpus and link files (as [zenodo_build()]).
#' @export
zenodo_fetch <- function(community = NULL, query = NULL, ids = NULL, communities = NULL,
                         resource_type = NULL, from = NULL, to = NULL, interval = NULL,
                         recheck_interval = NULL, recheck_per_run = NULL, select = NULL,
                         project_folder, name = "zenodo", full = FALSE,
                         versions = NULL, stats = NULL, parquet_split = NULL) {
  check_name(name)
  dir <- file.path(project_folder, "raw", name)
  rec_file <- file.path(dir, "_query.json")
  old <- if (file.exists(rec_file)) jsonlite::read_json(rec_file, simplifyVector = TRUE)
  # check and build settings: as last time unless given
  interval <- interval %||% old$source$interval %||% "year"
  if (is.null(recheck_interval) && is.null(recheck_per_run) && !is.null(old$source$recheck)) {
    recheck_interval <- old$source$recheck$interval
    recheck_per_run <- old$source$recheck$per_run
    if (match(recheck_interval, zenodo_intervals) >= match(interval, zenodo_intervals)) {
      message("Rolling recheck by ", recheck_interval, " switched off: not finer than `interval`.")
      recheck_interval <- recheck_per_run <- NULL
    }
  }
  if (identical(as.numeric(recheck_per_run), 0)) recheck_interval <- recheck_per_run <- NULL
  versions <- match.arg(versions %||% old$build$versions %||% "latest", c("latest", "all"))
  stats <- isTRUE(stats %||% old$build$stats)
  split <- check_split(parquet_split %||% old$build$parquet_split %||% "none")
  cfg <- zenodo_source(community, query, ids, communities, resource_type, from, to, interval,
                       recheck_interval, recheck_per_run, select)
  if (!is.null(old) && !full && !same_source(old$source, cfg)) {
    stop("`", name, "` was downloaded with other arguments (see ", rec_file, "). ",
         "Use the same arguments, `zenodo_update()`, or `full = TRUE` to redefine it.",
         call. = FALSE)
  }
  started <- Sys.time()
  requests <- zenodo_requests()
  if (!is.null(cfg$ids)) {
    cfg$parents <- if (!full && !is.null(old$source$parents)) old$source$parents else zenodo_resolve_ids(cfg$ids)
  }
  if (full) old$updated_watermark <- NULL
  if (is.null(old)) {
    # first download: record the arguments now, so that an interrupted download is resumed
    # (not mixed with other arguments) and edits made meanwhile are caught by the watermark
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    jsonlite::write_json(list(source = cfg,
                              updated_watermark = format(started, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
                              build = list(versions = versions, stats = stats, parquet_split = split),
                              finished = NULL),
                         rec_file, auto_unbox = TRUE, pretty = TRUE, null = "null", digits = NA)
  }

  zenodo_convert_layout(dir, split)
  changed <- check_zenodo(cfg, dir, full, old$recheck_last)
  change <- fetch_zenodo(cfg, changed, dir, full, split)
  if (!is.null(old$updated_watermark)) {
    since <- format(as.POSIXct(old$updated_watermark, tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ") - 86400,
                    "%Y-%m-%dT%H:%M:%S", tz = "UTC")
    n_upd <- zenodo_upsert_updated(cfg, dir, since, split)
    if (n_upd) {
      change <- change %||% list(date = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
      change$edited_records <- n_upd
    }
  }

  d <- zenodo_id_table(dir, c("id", "conceptrecid"))
  rec <- list(
    source = cfg,
    zenodo_url = zenodo_url(cfg),
    zenodo_query = zenodo_query(cfg, cfg$from, cfg$to),
    zenodo_web_url = zenodo_web_url(cfg),
    records = nrow(d),
    deposits = length(unique(d$conceptrecid)),
    requests = zenodo_requests() - requests,
    started = format(started, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    finished = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    updated_watermark = format(started, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    recheck_last = attr(changed, "recheck_last"),
    check = list(interval = cfg$interval, changed = changed$bucket),
    last_change = change %||% old$last_change,
    build = list(versions = versions, stats = stats, parquet_split = split),
    openalexImportZenodo = as.character(utils::packageVersion("openalexImportZenodo"))
  )
  write_query_record(rec, dir)
  if (!nrow(d)) { # nothing on Zenodo (any more): no corpus
    message("No records for `", name, "`; no corpus.")
    for (part in c("corpus", "links")) unlink(file.path(project_folder, part, paste0("query=", name)), recursive = TRUE)
    return(invisible(NULL))
  }
  zenodo_build(project_folder, name, versions = versions, stats = stats, parquet_split = split)
}

check_name <- function(name) {
  if (!(is.character(name) && length(name) == 1 && grepl("^[A-Za-z0-9][A-Za-z0-9_.-]*$", name))) {
    stop("`name` must be one word of letters, digits, `_`, `.` or `-`.", call. = FALSE)
  }
}

# The fields that define what is downloaded (everything but the resolved `parents`).
same_source <- function(a, b) {
  # not `interval` / `recheck`: they only set the check, and can change in every call
  f <- c("community", "query", "ids", "communities", "resource_type", "from", "to", "select")
  norm <- function(x) lapply(f, function(k) as.character(unlist(x[[k]])))
  identical(norm(a), norm(b))
}

write_query_record <- function(rec, dir) {
  jsonlite::write_json(rec, file.path(dir, "_query.json"), auto_unbox = TRUE, pretty = TRUE,
                       null = "null", digits = NA)
  writeLines(query_html(rec, zenodo_part_counts(dir)), file.path(dir, "_query.html"))
}

# A readable, self-contained page of the query record.
query_html <- function(rec, counts) {
  esc <- function(x) {
    x <- gsub("&", "&amp;", as.character(x), fixed = TRUE)
    x <- gsub("<", "&lt;", x, fixed = TRUE)
    gsub(">", "&gt;", x, fixed = TRUE)
  }
  row <- function(k, v) sprintf("<tr><th>%s</th><td>%s</td></tr>", esc(k), v)
  s <- rec$source
  src <- c(
    if (!is.null(s$community)) row("Community", sprintf('<a href="https://zenodo.org/communities/%1$s">%1$s</a>', esc(s$community))),
    if (!is.null(s$query)) row("Search", sprintf("<code>%s</code>", esc(s$query))),
    if (!is.null(s$ids)) row("Records", esc(toString(s$ids))),
    if (!is.null(s$communities)) row("In communities", esc(toString(s$communities))),
    if (!is.null(s$resource_type)) row("Resource types", esc(toString(s$resource_type))),
    row("Created", esc(sprintf("%s to %s", s$from %||% "start", s$to %||% "now"))),
    row("Check interval", esc(s$interval)),
    if (!is.null(s$recheck)) row("Rolling recheck", esc(sprintf("%d %s(s) per run", s$recheck$per_run, s$recheck$interval))),
    row("Stored", esc(if (is.null(s$select)) "complete records" else toString(s$select)))
  )
  ch <- rec$last_change
  run <- c(
    row("Zenodo query", sprintf('<code>%s</code><br><a href="%s">open on zenodo.org</a>',
                                esc(rec$zenodo_query), esc(rec$zenodo_web_url))),
    row("Records (versions)", esc(rec$records)),
    row("Deposits", esc(rec$deposits)),
    row("Last check", esc(sprintf("%s intervals; changed: %s", rec$check$interval,
                                  if (length(rec$check$changed)) toString(rec$check$changed) else "none"))),
    row("Last run", esc(sprintf("%s to %s, %d requests", rec$started, rec$finished, rec$requests))),
    if (!is.null(ch)) row("Last change", esc(sprintf(
      "%s: %s deposits added, %s removed; %s records added, %s removed; %s edited", ch$date,
      ch$added_deposits %||% 0, ch$removed_deposits %||% 0, ch$added_records %||% 0,
      ch$removed_records %||% 0, ch$edited_records %||% 0)))
  )
  iv <- if (length(counts)) sprintf("<tr><td>%s</td><td>%s</td></tr>", esc(names(counts)), counts) else character()
  c("<!doctype html>", '<html lang="en"><head><meta charset="utf-8">',
    "<title>Zenodo query</title>",
    "<style>body{font-family:system-ui,sans-serif;max-width:60rem;margin:2rem auto;padding:0 1rem}",
    "table{border-collapse:collapse;margin-bottom:1.5rem}th,td{text-align:left;padding:.25rem .75rem;border-bottom:1px solid #ddd;vertical-align:top}",
    "code{white-space:pre-wrap}</style></head><body>",
    "<h1>Zenodo query</h1>", "<h2>Source</h2><table>", src, "</table>",
    "<h2>Run</h2><table>", run, "</table>",
    "<h2>Stored records</h2><table><tr><th>Folder</th><th>Records</th></tr>", iv, "</table>",
    sprintf("<p>openalexImportZenodo %s</p></body></html>", esc(rec$openalexImportZenodo)))
}
