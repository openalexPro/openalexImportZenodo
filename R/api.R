# Copied from zenodo-openalex-collection (R/api_key.R, R/zenodo_get.R); adapted.

#' Zenodo token
#'
#' The default `api_key` of [zenodo_fetch()] and [zenodo_update()], looked up as
#' `openalexPro::pro_api_key()` does, in this order:
#'
#' 1. the R option `openalexImportZenodo$api_key`
#'    (`options(openalexImportZenodo = list(api_key = "..."))`);
#' 2. the environment variable `openalexImportZenodo.api_key`;
#' 3. the system keyring entry `API_zenodo` (if the keyring package is installed).
#'
#' A token (no scopes needed, from <https://zenodo.org/account/settings/applications>)
#' allows 100 instead of 25 records per request.
#'
#' @return The token, or `NULL` if none is found.
#' @examples
#' \dontrun{
#' keyring::key_set("API_zenodo")
#' zenodo_api_key()
#' }
#' @export
zenodo_api_key <- function() {
  key <- getOption("openalexImportZenodo")$api_key
  if (is.null(key) || !nzchar(key)) key <- Sys.getenv("openalexImportZenodo.api_key")
  if (!nzchar(key) && requireNamespace("keyring", quietly = TRUE)) {
    key <- tryCatch(keyring::key_get("API_zenodo"), error = function(e) "")
  }
  if (nzchar(key)) key
}

# Token for zenodo_get(): zenodo_fetch() sets `.token$key` for its run ("" = anonymous);
# outside of it, zenodo_api_key().
.token <- new.env()
zenodo_token <- function() .token$key %||% zenodo_api_key() %||% ""
check_api_key <- function(api_key) {
  if (!is.null(api_key) && (!is.character(api_key) || length(api_key) != 1 || is.na(api_key))) {
    stop("`api_key` must be NULL or a single string.", call. = FALSE)
  }
  api_key %||% ""
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
# Sends the Zenodo token (zenodo_token()) when there is one (allows 100 records per page).
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
  token <- zenodo_token()
  if (nzchar(token)) req <- httr2::req_auth_bearer_token(req, token)
  zenodo_requests(1)
  req |>
    httr2::req_perform() |>
    httr2::resp_body_json()
}

# Records per page: 100 with a token, 25 anonymously.
zenodo_page_size <- function() if (nzchar(zenodo_token())) 100 else 25
