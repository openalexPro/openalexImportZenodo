# Table `links` in `con` from the related identifiers of all versions in table `rs`.
#
# Shaped like OpenAlex's links (api.openalex.org/links: origin, target, link_type), one row
# per link in the direction "origin does X to target": relations Zenodo declares the other
# way round (isCitedBy, hasPart, ...) are flipped (relations.csv). Zenodo records and DOIs
# that are deposits of the source become `zenodo:<concept record ID>`; other DOIs
# `https://doi.org/<doi>` (arXiv IDs as their DataCite DOI, handles that are DOIs as DOIs);
# URLs stay as given; anything else becomes `<scheme>:<identifier>` (ecosystem standard K4)
# if the scheme is one of `link_schemes`, else the link is left out (it stays in the work's
# `zenodo_related`). Extra columns carry the `zenodo_` prefix (S5, K1).
# Relations between versions of one deposit are dropped; a link declared on several
# versions (or by both sides) is kept once, from the newest declaration.
build_links <- function(con) {
  DBI::dbExecute(con, sprintf("
CREATE TEMP TABLE links AS
WITH ids AS (
  SELECT id AS recid, conceptrecid FROM rs
  UNION SELECT conceptrecid, conceptrecid FROM rs
), rel AS (
  SELECT r.conceptrecid AS dep, r.id AS declared_on, r.version_index, r.created,
         unnest(r.related) AS x
  FROM rs r
), n AS (
  SELECT *,
    trim(x.identifier) AS idn,
    lower(x.scheme) AS scheme,
    lower(x.relation_type.id) AS declared
  FROM rel WHERE x.identifier IS NOT NULL AND x.relation_type.id IS NOT NULL
), d AS (
  SELECT *,
    CASE
      WHEN scheme = 'arxiv' THEN '10.48550/arxiv.' || lower(regexp_replace(idn, '^arxiv:', '', 'i'))
      WHEN scheme = 'doi' OR regexp_matches(idn, '^(https?://(dx\\.)?doi\\.org/|doi:)10\\.', 'i')
        OR (scheme = 'handle' AND regexp_matches(idn, '^10\\.[0-9]{4,}/'))
        THEN lower(regexp_replace(idn, '^(https?://(dx\\.)?doi\\.org/|doi:)', '', 'i'))
    END AS doi
  FROM n
), z AS (
  SELECT *,
    coalesce(regexp_extract(doi, '^10\\.5281/zenodo\\.([0-9]+)$', 1),
             regexp_extract(idn, 'zenodo\\.org/(records?|deposit|uploads)/([0-9]+)', 2)) AS zn
  FROM d
), t AS (
  SELECT z.*, ids.conceptrecid AS target_dep,
    CASE
      WHEN ids.conceptrecid IS NOT NULL THEN 'zenodo:' || ids.conceptrecid
      WHEN doi IS NOT NULL THEN 'https://doi.org/' || doi
      WHEN nullif(zn, '') IS NOT NULL THEN 'https://doi.org/10.5281/zenodo.' || zn
      WHEN regexp_matches(idn, '^https?://', 'i') THEN idn
      WHEN scheme IN (%s) THEN scheme || ':' || regexp_replace(idn, '^' || scheme || ':', '', 'i')
    END AS other
  FROM z LEFT JOIN ids ON ids.recid = nullif(z.zn, '')
), o AS (
  SELECT t.*,
    coalesce(rl.relation, t.declared) AS relation,
    coalesce(rl.flip, false) AS flip,
    CASE WHEN rl.link_type IS NOT NULL THEN 'https://openalex.org/link-types/' || rl.link_type END AS link_type
  FROM t LEFT JOIN relations rl ON rl.declared = t.declared
  WHERE t.target_dep IS DISTINCT FROM t.dep AND t.other IS NOT NULL
)
SELECT
  CASE WHEN flip THEN other ELSE 'zenodo:' || dep END AS origin,
  CASE WHEN flip THEN 'zenodo:' || dep ELSE other END AS target,
  link_type,
  upper(relation[1]) || relation[2:] AS relation,
  x.relation_type.id AS zenodo_relation_declared,
  scheme AS zenodo_scheme,
  x.resource_type.id AS zenodo_related_type,
  starts_with(CASE WHEN flip THEN other ELSE 'zenodo:' || dep END, 'zenodo:') AS origin_in_corpus,
  starts_with(CASE WHEN flip THEN 'zenodo:' || dep ELSE other END, 'zenodo:') AS target_in_corpus,
  declared_on AS zenodo_declared_on,
  dep,
  row_number() OVER (
    PARTITION BY CASE WHEN flip THEN other ELSE 'zenodo:' || dep END,
                 CASE WHEN flip THEN 'zenodo:' || dep ELSE other END, relation
    ORDER BY version_index DESC NULLS LAST, created DESC) AS rank
FROM o
QUALIFY rank = 1", paste(sql_str(link_schemes), collapse = ", ")))
}

# Identifier schemes written as `<scheme>:<identifier>` (STANDARD.md I7, without doi/url,
# which are written as URLs).
link_schemes <- c("ark", "arxiv", "bibcode", "ean13", "eissn", "handle", "igsn", "isbn", "issn",
                  "istc", "lissn", "lsid", "pmid", "purl", "upc", "urn", "w3id", "orcid", "ror")

#' Links between Zenodo deposits and other works
#'
#' Reads the link table written by [zenodo_fetch()]: one row per link from Zenodo's related
#' identifiers, shaped like OpenAlex's links (`api.openalex.org/links`): `origin`,
#' `target`, `link_type`, in the direction "origin does X to target" (a relation declared
#' the other way round, such as `isCitedBy`, is flipped). Deposits of the source are
#' `zenodo:<concept record ID>`, DOIs `https://doi.org/<doi>`, other URLs as given, other
#' identifiers `<scheme>:<identifier>` (e.g. `isbn:978...`), as the openalexPro ecosystem
#' standard asks (K4). Related identifiers of other schemes are not links; they are in the
#' work's `zenodo_related`.
#'
#' Columns: `origin`, `target`, `link_type` (OpenAlex link type URL, e.g.
#' `https://openalex.org/link-types/citation`, or `NA` for relations OpenAlex has no type
#' for, such as `isSupplementTo`), `origin_in_corpus`, `target_in_corpus`,
#' `relation` (DataCite relation type in the stored direction, e.g. `Cites`), `zenodo_relation_declared`
#' (as declared on Zenodo), `zenodo_scheme` and `zenodo_related_type` (scheme and Zenodo
#' resource type of the related identifier), `zenodo_declared_on` (Zenodo record ID of the
#' version that declared it), `query` (source name).
#'
#' @param project_folder Project folder.
#' @param name Names of the sources; `NULL` for all.
#' @param origin,target,link_type Keep only links with these values (any of them).
#'   `link_type` may be given short (`"citation"`).
#' @return A data frame.
#' @export
zenodo_links <- function(project_folder, name = NULL, origin = NULL, target = NULL,
                         link_type = NULL) {
  dir <- file.path(project_folder, "links")
  if (!dir.exists(dir)) stop("No link table in ", project_folder, "; run zenodo_fetch() first.", call. = FALSE)
  # ponytail: filtered in R after reading; push filters into arrow if link tables get large
  d <- as.data.frame(dplyr::collect(arrow::open_dataset(dir)))
  keep <- rep(TRUE, nrow(d))
  if (!is.null(name)) keep <- keep & d$query %in% name
  if (!is.null(origin)) keep <- keep & d$origin %in% origin
  if (!is.null(target)) keep <- keep & d$target %in% target
  if (!is.null(link_type)) {
    lt <- ifelse(grepl("^https?://", link_type), link_type,
                 paste0("https://openalex.org/link-types/", link_type))
    keep <- keep & d$link_type %in% lt
  }
  d <- d[keep, , drop = FALSE]
  rownames(d) <- NULL
  d
}
