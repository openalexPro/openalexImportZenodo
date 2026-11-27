#' Update sources
#'
#' Runs [zenodo_fetch()] for each source with the arguments stored in its
#' `raw/<name>/_query.json` (the query, and the check and build settings of the last call),
#' which also rebuilds its corpus and link table.
#'
#' @param project_folder Project folder.
#' @param name Names of the sources; `NULL` (default) for all sources in `project_folder`.
#' @param interval Check interval for this update (see [zenodo_fetch()]); `NULL`: as last time.
#' @param api_key Zenodo token, as in [zenodo_fetch()].
#' @return Invisibly, the names of the sources updated.
#' @export
zenodo_update <- function(project_folder, name = NULL, interval = NULL,
                          api_key = zenodo_api_key()) {
  name <- name %||% zenodo_names(project_folder)
  for (n in name) {
    rec_file <- file.path(project_folder, "raw", n, "_query.json")
    if (!file.exists(rec_file)) stop("No source `", n, "` in ", project_folder, ".", call. = FALSE)
    rec <- jsonlite::read_json(rec_file, simplifyVector = TRUE)
    s <- rec$source
    message("== ", n)
    zenodo_fetch(community = s$community, query = s$query, ids = s$ids,
                 communities = s$communities, resource_type = s$resource_type,
                 from = s$from, to = s$to, interval = interval, select = s$select,
                 project_folder = project_folder, name = n, api_key = api_key)
  }
  invisible(name)
}

# Sources in a project folder: raw/<name>/ with a _query.json.
zenodo_names <- function(project_folder) {
  d <- list.dirs(file.path(project_folder, "raw"), recursive = FALSE, full.names = FALSE)
  d[file.exists(file.path(project_folder, "raw", d, "_query.json"))]
}

#' Copy the corpus of some sources to another folder
#'
#' Copies `corpus/query=<name>/` and `links/query=<name>/` of the given sources to
#' `out/corpus/` and `out/links/`, e.g. to serve a subset with openalexAPI or to combine it
#' with other corpora.
#'
#' @param project_folder Project folder.
#' @param out Output folder, not inside `project_folder`.
#' @param name Names of the sources; `NULL` for all built sources.
#' @return Invisibly, `out`.
#' @export
zenodo_as_corpus <- function(project_folder, out, name = NULL) {
  if (startsWith(paste0(real_path(out), "/"), paste0(real_path(project_folder), "/"))) {
    stop("`out` must not be inside `project_folder`.", call. = FALSE)
  }
  built <- sub("^query=", "", list.dirs(file.path(project_folder, "corpus"), recursive = FALSE,
                                       full.names = FALSE))
  name <- name %||% built
  if (length(miss <- setdiff(name, built))) {
    stop("Not built: ", toString(miss), "; run zenodo_fetch() first.", call. = FALSE)
  }
  for (part in c("corpus", "links")) {
    for (n in name) {
      from <- file.path(project_folder, part, paste0("query=", n))
      if (!dir.exists(from)) next
      to <- file.path(out, part)
      dir.create(to, recursive = TRUE, showWarnings = FALSE)
      unlink(file.path(to, basename(from)), recursive = TRUE)
      file.copy(from, to, recursive = TRUE)
    }
  }
  # the selection has its own data, so its own fingerprint (D5)
  if (dir.exists(file.path(out, "corpus"))) write_dataset_marker(file.path(out, "corpus"))
  invisible(out)
}

# Absolute path with symlinks resolved, also for paths that don't exist yet (/tmp -> /private/tmp).
# Copied from openalexImportPolicy (R/corpus.R).
real_path <- function(p) {
  p <- path.expand(p)
  rest <- character()
  while (!file.exists(p) && dirname(p) != p) {
    rest <- c(basename(p), rest)
    p <- dirname(p)
  }
  paste(c(normalizePath(p, winslash = "/"), rest), collapse = "/")
}
