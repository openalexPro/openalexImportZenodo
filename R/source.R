`%||%` <- function(x, y) if (is.null(x)) y else x

# The source spec: what zenodo_fetch() downloads, built from its arguments and stored in
# _query.json. Exactly one of `community`, `query` or `ids`. Plays the role of the `cfg`
# entry of zenodo-openalex-collection's config.yml.
zenodo_source <- function(community = NULL, query = NULL, ids = NULL, communities = NULL,
                          resource_type = NULL, from = NULL, to = NULL, interval = "year",
                          recheck_interval = NULL, recheck_per_run = NULL, select = NULL) {
  given <- c(community = !is.null(community), query = !is.null(query), ids = !is.null(ids))
  if (sum(given) != 1) stop("Give exactly one of `community`, `query` or `ids`.", call. = FALSE)
  chr1 <- function(x, arg) {
    if (!is.null(x) && !(is.character(x) && length(x) == 1 && !is.na(x) && nzchar(x))) {
      stop("`", arg, "` must be a single string.", call. = FALSE)
    }
  }
  chrn <- function(x, arg) {
    if (!is.null(x) && !(is.character(x) && length(x) && !anyNA(x) && all(nzchar(x)))) {
      stop("`", arg, "` must be a character vector without empty values.", call. = FALSE)
    }
  }
  chr1(community, "community"); chr1(query, "query"); chr1(from, "from"); chr1(to, "to")
  chrn(as.character(ids %||% "x"), "ids"); chrn(communities, "communities")
  chrn(resource_type, "resource_type"); chrn(select, "select")
  if (!isTRUE(interval %in% zenodo_intervals)) {
    stop("`interval` must be one of ", toString(zenodo_intervals), ".", call. = FALSE)
  }
  rank <- function(x) match(x, zenodo_intervals)
  if (xor(is.null(recheck_interval), is.null(recheck_per_run))) {
    stop("Give both `recheck_interval` and `recheck_per_run`, or neither.", call. = FALSE)
  }
  if (!is.null(recheck_interval)) {
    if (!isTRUE(recheck_interval %in% zenodo_intervals) || rank(recheck_interval) >= rank(interval)) {
      stop("`recheck_interval` must be an interval finer than `interval`.", call. = FALSE)
    }
    if (!(is.numeric(recheck_per_run) && length(recheck_per_run) == 1 && recheck_per_run >= 1 &&
          recheck_per_run == round(recheck_per_run))) {
      stop("`recheck_per_run` must be a positive whole number.", call. = FALSE)
    }
  }
  list(
    community = community, query = query, ids = if (!is.null(ids)) as.character(ids),
    communities = communities, resource_type = resource_type, from = from, to = to,
    interval = interval,
    recheck = if (!is.null(recheck_interval)) {
      list(interval = recheck_interval, per_run = as.integer(recheck_per_run))
    },
    select = select
  )
}

# Search URL of the source.
zenodo_url <- function(cfg) {
  if (!is.null(cfg$community)) {
    sprintf("https://zenodo.org/api/communities/%s/records", cfg$community)
  } else {
    "https://zenodo.org/api/records"
  }
}

# Zenodo search string for records of the source created in [from, to). NULL = open-ended.
# For `ids`, `cfg$parents` holds the deposits (concept record IDs) they resolved to.
# `extra`: another condition, ANDed (e.g. on `updated`).
zenodo_query <- function(cfg, from = NULL, to = NULL, extra = NULL) {
  b <- function(x) if (is.null(x) || is.na(x)) "*" else sprintf('"%s"', x)
  or <- function(field, x) sprintf("%s:(%s)", field, paste(x, collapse = " OR "))
  parts <- c(
    if (!is.null(cfg$query)) sprintf("(%s)", cfg$query),
    if (!is.null(cfg$ids)) or("parent.id", cfg$parents),
    if (!is.null(cfg$communities)) or("parent.communities.entries.slug", cfg$communities),
    sprintf("created:[%s TO %s}", b(from), b(to)),
    extra
  )
  paste(parts, collapse = " AND ")
}

# Search request of the source (all versions); `...`: size, sort, page.
zenodo_search <- function(cfg, q, ...) {
  zenodo_get(zenodo_url(cfg), allversions = "true", q = q, type = cfg$resource_type, ...)
}

# Number of records (versions) matching `q`.
zenodo_count <- function(cfg, q) {
  zenodo_search(cfg, q, size = 1)$hits$total
}

# The same search on zenodo.org, for people (the link in _query.html).
zenodo_web_url <- function(cfg) {
  base <- if (!is.null(cfg$community)) {
    sprintf("https://zenodo.org/communities/%s/records", cfg$community)
  } else {
    "https://zenodo.org/search"
  }
  q <- zenodo_query(cfg, cfg$from, cfg$to)
  q <- sub("( AND )?created:\\[\\* TO \\*\\}$", "", q) # drop the open range
  url <- paste0(base, "?q=", utils::URLencode(q, reserved = TRUE), "&all_versions=true")
  for (t in cfg$resource_type) url <- paste0(url, "&f=resource_type%3A", utils::URLencode(t, reserved = TRUE))
  url
}

# Deposits (concept record IDs) of record IDs and DOIs: record IDs and concept record IDs,
# Zenodo DOIs (10.5281/zenodo.<n>) of records or concepts, other DOIs of records.
zenodo_resolve_ids <- function(ids) {
  ids <- trimws(sub("^(https?://(dx\\.)?doi\\.org/|doi:)", "", ids, ignore.case = TRUE))
  zen <- grepl("^10\\.5281/zenodo\\.[0-9]+$", ids, ignore.case = TRUE)
  num <- c(ids[grepl("^[0-9]+$", ids)], sub(".*\\.", "", ids[zen]))
  doi <- ids[!zen & !grepl("^[0-9]+$", ids)]
  q <- paste(c(
    if (length(num)) sprintf("id:(%1$s) OR parent.id:(%1$s)", paste(num, collapse = " OR ")),
    if (length(doi)) sprintf("doi:(%s)", paste(sprintf('"%s"', doi), collapse = " OR "))
  ), collapse = " OR ")
  res <- zenodo_get("https://zenodo.org/api/records", allversions = "true", q = q,
                    size = zenodo_page_size())
  parents <- character()
  repeat {
    parents <- c(parents, vapply(res$hits$hits, function(h) as.character(h$parent$id), ""))
    if (is.null(res$links[["next"]])) break
    res <- zenodo_get(res$links[["next"]])
  }
  parents <- sort(unique(parents))
  if (!length(parents)) stop("None of `ids` was found on Zenodo.", call. = FALSE)
  parents
}
