# Copied from zenodo-openalex-collection (R/api_key.R, R/zenodo_get.R); adapted.

# Key from env var `name` (e.g. on CI), else from the system keyring service `name`, else "".
api_key <- function(name) {
  key <- Sys.getenv(name)
  if (!nzchar(key) && requireNamespace("keyring", quietly = TRUE)) {
    key <- tryCatch(keyring::key_get(name), error = function(e) "")
  }
  key
}

# Requests sent in this R session (reported in _query.json).
zenodo_requests <- local({
  n <- 0
  function(add = 0) {
    n <<- n + add
    n
  }
})

# GET a Zenodo API URL and return the parsed JSON, in the InvenioRDM format.
# Sends the Zenodo token API_zenodo_ro when available (allows 100 records per page).
# Zenodo allows 30 search requests per minute (also with a token): evenly spaced at one
# request per 2.2 s (~27/min); a 429 waits until Zenodo's rate limit window resets.
# Vector arguments (e.g. `type`) are repeated in the URL; NULL arguments are left out.
zenodo_get <- function(url, ...) {
  req <- httr2::request(url) |>
    httr2::req_url_query(..., .multi = "explode") |>
    httr2::req_headers(Accept = "application/vnd.inveniordm.v1+json") |>
    httr2::req_throttle(capacity = 1, fill_time_s = 2.2, realm = "zenodo") |>
    httr2::req_retry(
      max_tries = 5,
      is_transient = function(r) httr2::resp_status(r) %in% c(429, 500, 502, 503, 504),
      after = function(r) {
        reset <- suppressWarnings(as.numeric(httr2::resp_header(r, "x-ratelimit-reset")))
        if (httr2::resp_status(r) == 429 && length(reset) && !is.na(reset)) {
          max(1, reset - as.numeric(Sys.time()) + 1)
        } else NA # default backoff
      }
    ) |>
    httr2::req_error(body = function(r) httr2::resp_body_string(r))
  token <- api_key("API_zenodo_ro")
  if (nzchar(token)) req <- httr2::req_auth_bearer_token(req, token)
  zenodo_requests(1)
  req |>
    httr2::req_perform() |>
    httr2::resp_body_json()
}

# Records per page: 100 with a token, 25 anonymously.
zenodo_page_size <- function() if (nzchar(api_key("API_zenodo_ro"))) 100 else 25
