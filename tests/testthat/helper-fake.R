# Offline helpers: no test needs the network. Zenodo is replaced by a fake that serves
# InvenioRDM-like hits from a local list (local_fake_zenodo()).

# One InvenioRDM-like hit (record = one version of deposit `parent`).
hit <- function(id, parent = id, created = "2024-03-01T10:00:00+00:00", updated = created,
                index = 1L, latest = TRUE, title = paste("Record", id), related = list(),
                conceptdoi = TRUE, creators = list(list(person_or_org = list(name = "Doe, Jane"))),
                resource_type = "dataset", extra = list()) {
  h <- list(
    id = as.character(id),
    created = created,
    updated = updated,
    parent = list(id = as.character(parent),
                  communities = list(entries = list(list(slug = "test-community")))),
    pids = list(doi = list(identifier = paste0("10.5281/zenodo.", id))),
    versions = list(index = index, is_latest = latest),
    access = list(record = "public", files = "public", status = "open"),
    files = list(entries = list(`paper.pdf` = list(key = "paper.pdf", size = 10, checksum = "md5:x",
                                                   mimetype = "application/pdf"))),
    metadata = list(title = title, publication_date = substr(created, 1, 10),
                    resource_type = list(id = resource_type), creators = creators,
                    related_identifiers = related, rights = list(list(id = "cc-by-4.0")),
                    description = "<p>An <b>abstract</b> &amp; more</p>"),
    stats = list(all_versions = list(views = 5L, downloads = 2L))
  )
  if (conceptdoi) h$parent$pids <- list(doi = list(identifier = paste0("10.5281/zenodo.", parent)))
  utils::modifyList(h, extra)
}

rel <- function(identifier, relation, scheme = "doi", resource_type = NULL) {
  r <- list(identifier = identifier, scheme = scheme, relation_type = list(id = relation))
  if (!is.null(resource_type)) r$resource_type <- list(id = resource_type)
  r
}

# A fake zenodo_get(): answers counts (size = 1) and paged searches over `env$hits` for
# queries built by zenodo_query() (created window, optional parent.id filter and updated
# filter). `env$hits` can be changed between calls to simulate Zenodo changing.
fake_zenodo <- function(hits) {
  env <- new.env()
  env$hits <- hits
  env$calls <- 0
  t <- function(x, open) {
    x[x == "*"] <- open
    as.POSIXct(substr(gsub('"', "", x), 1, 19), tz = "UTC",
               tryFormats = c("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"))
  }
  sel <- function(q) {
    h <- env$hits
    m <- regmatches(q, regexec('created:\\[(\\*|"[^"]*") TO (\\*|"[^"]*")\\}', q))[[1]]
    if (length(m)) {
      ct <- t(vapply(h, function(x) x$created, ""), "*")
      lo <- t(m[2], "1900-01-01"); hi <- t(m[3], "2999-01-01")
      h <- h[ct >= lo & ct < hi]
    }
    u <- regmatches(q, regexec('updated:\\["([^"]*)" TO \\*\\]', q))[[1]]
    if (length(u)) h <- h[t(vapply(h, function(x) x$updated, ""), "*") >= t(u[2], "*")]
    p <- regmatches(q, regexec("parent\\.id:\\(([^)]*)\\)", q))[[1]]
    if (length(p)) h <- h[vapply(h, function(x) x$parent$id, "") %in% strsplit(p[2], " OR ")[[1]]]
    h
  }
  env$get <- function(url, ..., size = 25, q = NULL, page = 1) {
    env$calls <- env$calls + 1
    if (env$calls > 5000) stop("fake Zenodo: too many requests")
    if (startsWith(url, "fake:")) { # next page link: fake:<page>:<size>:<q>
      p <- strsplit(sub("^fake:", "", url), ":", fixed = TRUE)[[1]]
      page <- as.integer(p[1]); size <- as.integer(p[2]); q <- paste(p[-(1:2)], collapse = ":")
    }
    h <- sel(q)
    rows <- seq_along(h)
    rows <- rows[rows > (page - 1) * size & rows <= page * size]
    nxt <- if (page * size < length(h)) sprintf("fake:%d:%d:%s", page + 1, size, q)
    list(hits = list(total = length(h), hits = h[rows]), links = list(`next` = nxt))
  }
  env
}

# Use the fake for the rest of the calling test.
local_fake_zenodo <- function(hits, env = parent.frame()) {
  z <- fake_zenodo(hits)
  testthat::local_mocked_bindings(zenodo_get = z$get, zenodo_api_key = function() NULL, .env = env)
  z
}

local_project <- function(env = parent.frame()) withr::local_tempdir(.local_envir = env)

quiet <- function(expr) suppressMessages(expr)
