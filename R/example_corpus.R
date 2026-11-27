#' Write a small example corpus (openalexPro ecosystem standard, P7)
#'
#' Builds a corpus from the stored records of seven deposits of the IPBES Zenodo
#' community shipped with the package (`inst/extdata/example/`), offline and
#' through the same code as [zenodo_fetch()] uses ([zenodo_build()]): the corpus
#' in `out/corpus/query=example/` and the link table in `out/links/query=example/`.
#' The deposits cite each other, have several versions, and link to DOIs,
#' a handle and an ISBN outside the corpus.
#'
#' Used by the package's tests and by the ecosystem's compliance checks.
#' @param out Project folder to write into.
#' @return The path of the corpus folder.
#' @export
#' @examples
#' corpus <- zenodo_example_corpus(tempfile())
#' list.files(corpus, recursive = TRUE)
zenodo_example_corpus <- function(out = tempfile()) {
  dir.create(file.path(out, "raw"), recursive = TRUE, showWarnings = FALSE)
  src <- system.file("extdata", "example", "raw", "example", package = "openalexImportZenodo", mustWork = TRUE)
  file.copy(src, file.path(out, "raw"), recursive = TRUE)
  suppressMessages(zenodo_build(out, "example"))
  file.path(out, "corpus")
}
