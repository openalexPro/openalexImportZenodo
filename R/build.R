#' Build the works corpus and the link table of a source
#'
#' [zenodo_fetch()] runs this after each download, so it is only needed to rebuild with
#' other `versions` or `stats`, or after updating the package, without downloading again.
#' It maps the stored Zenodo records of `name` to the OpenAlex works schema and writes
#'
#' - `<project_folder>/corpus/query=<name>/data.parquet`, with a copy of the source's
#'   `_query.json` and `_query.html`: one row per deposit (all versions
#'   of a Zenodo upload), from its newest version, `id` = `zenodo:<concept record ID>`;
#' - `<project_folder>/links/query=<name>/data.parquet`: the links from Zenodo's related
#'   identifiers, shaped like OpenAlex's links (see [zenodo_links()]).
#'
#' Only Zenodo data is used; nothing is requested from OpenAlex. Fields Zenodo has no data
#' for (`cited_by_count`, `topics`, ...) are absent.
#'
#' Mapped OpenAlex columns: `id`, `doi` (concept DOI, else record DOI), `title`,
#' `display_name`, `abstract` (description as plain text), `publication_date`,
#' `publication_year`, `type` (from the Zenodo resource type), `language` (ISO 639-1),
#' `authorships` (creators; ORCID; affiliations with ROR IDs as `institutions`),
#' `primary_location`, `open_access`, `keywords` (subjects), `funders`, `awards`, `biblio`,
#' `referenced_works` (deposits of the same source cited according to the related
#' identifiers), `ids`, `created_date`, `updated_date`. Zenodo extras as `zenodo_*`
#' columns: record and concept IDs and DOIs, version and all versions, resource type,
#' publisher, licence, access, communities, related identifiers as declared, free-text
#' references, files, and (as JSON text) contributors, locations, dates, additional
#' descriptions, alternative identifiers and Software Heritage IDs.
#'
#' @param project_folder Project folder.
#' @param name Name of the source.
#' @param versions `"latest"` (default): one row per deposit, from its newest version;
#'   `"all"`: one row per version, `id` = `zenodo:<record ID>`. Links are always between
#'   deposits.
#' @param stats Add Zenodo's views and downloads (`zenodo_stats`) and the time they were
#'   downloaded (`zenodo_stats_date`). They grow daily without changing a record, so they
#'   are only as recent as the record's last download. Needs `stats` stored (the default
#'   of [zenodo_fetch()]).
#'
#' @return Invisibly, the paths of the corpus and link files.
#' @export
zenodo_build <- function(project_folder, name = "zenodo", versions = c("latest", "all"),
                         stats = FALSE) {
  check_name(name)
  versions <- match.arg(versions)
  raw <- file.path(project_folder, "raw", name)
  if (!length(list.files(raw, "[.]parquet$", recursive = TRUE))) {
    stop("No records for `", name, "` in ", raw, "; run zenodo_fetch() first.", call. = FALSE)
  }
  # No extensions are needed; shared_home = FALSE (duckdb >= 1.4) avoids writing to ~/.duckdb.
  drv <- if ("shared_home" %in% names(formals(duckdb::duckdb))) duckdb::duckdb(shared_home = FALSE) else duckdb::duckdb()
  con <- DBI::dbConnect(drv)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  for (t in c("languages", "resource_types", "relations")) {
    d <- utils::read.csv(system.file("extdata", paste0(t, ".csv"), package = "openalexImportZenodo"),
                         stringsAsFactors = FALSE, na.strings = "")
    duckdb::duckdb_register(con, t, d)
  }
  q <- function(x) as.character(DBI::dbQuoteString(con, x))
  DBI::dbExecute(con, sprintf(
    "CREATE TEMP TABLE r AS SELECT *, json_transform(json, %s) AS j
     FROM read_parquet(%s, hive_partitioning = false)",
    q(build_schema()), q(file.path(raw, "*", "*.parquet"))))
  build_links(con)

  corpus <- file.path(project_folder, "corpus", paste0("query=", name), "data.parquet")
  links <- file.path(project_folder, "links", paste0("query=", name), "data.parquet")
  write_parquet_sql(con, build_works_sql(name, versions, stats), corpus)
  write_parquet_sql(con, "SELECT * EXCLUDE (dep, rank) FROM links ORDER BY origin, target, relation", links)
  # the query record next to the data, as pro_fetch() does (`_` files are skipped by arrow
  # and openalexAPI)
  rec <- file.path(raw, c("_query.json", "_query.html"))
  file.copy(rec[file.exists(rec)], dirname(corpus), overwrite = TRUE)
  message(DBI::dbGetQuery(con, "SELECT count(DISTINCT conceptrecid) AS n FROM r")$n,
          " deposits -> ", corpus)
  invisible(c(corpus = corpus, links = links))
}

# COPY a query to a parquet file, replacing it only when complete.
write_parquet_sql <- function(con, sql, file) {
  dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(file, ".part")
  DBI::dbExecute(con, sprintf("COPY (%s) TO %s (FORMAT parquet, COMPRESSION zstd)", sql,
                              DBI::dbQuoteString(con, tmp)))
  if (!file.rename(tmp, file)) stop("Could not write ", file, call. = FALSE)
  file
}

# The parts of a record that are mapped, as a json_transform() structure. Missing parts
# (e.g. not stored because of `select`) become NULL.
build_schema <- function() {
  V <- "VARCHAR"
  idsch <- list(list(identifier = V, scheme = V))
  counts <- list(views = "BIGINT", unique_views = "BIGINT", downloads = "BIGINT",
                 unique_downloads = "BIGINT")
  s <- list(
    metadata = list(
      title = V, description = V, publication_date = V, version = V, publisher = V,
      resource_type = list(id = V),
      languages = list(list(id = V)),
      creators = list(list(
        person_or_org = list(name = V, type = V, identifiers = idsch),
        affiliations = list(list(id = V, name = V)))),
      subjects = list(list(subject = V)),
      rights = list(list(id = V)),
      funding = list(list(funder = list(id = V, name = V),
                          award = list(id = V, number = V, title = list(en = V)))),
      related_identifiers = list(list(identifier = V, scheme = V, relation_type = list(id = V),
                                      resource_type = list(id = V))),
      references = list(list(reference = V))
    ),
    parent = list(communities = list(entries = list(list(slug = V)))),
    access = list(record = V, files = V, status = V),
    files = list(entries = "MAP(VARCHAR, STRUCT(key VARCHAR, size BIGINT, checksum VARCHAR, mimetype VARCHAR))"),
    custom_fields = list(`journal:journal` = list(title = V, volume = V, issue = V, pages = V)),
    stats = list(this_version = counts, all_versions = counts)
  )
  as.character(jsonlite::toJSON(s, auto_unbox = TRUE))
}

# HTML description -> plain text.
sql_strip_html <- function(x) {
  x <- sprintf("regexp_replace(%s, '<[^>]*>', ' ', 'g')", x)
  for (e in list(c("&nbsp;", " "), c("&lt;", "<"), c("&gt;", ">"), c("&quot;", "\""),
                 c("&#39;", "''"), c("&amp;", "&"))) {
    x <- sprintf("replace(%s, '%s', '%s')", x, e[1], e[2])
  }
  sprintf("nullif(trim(regexp_replace(%s, '\\s+', ' ', 'g')), '')", x)
}

build_works_sql <- function(name, versions, stats) {
  m <- "r.j.metadata"
  files_public <- "coalesce(r.j.access.files = 'public', false)"
  record_url <- "'https://zenodo.org/records/' || r.id"
  pdf <- sprintf("list_filter(map_keys(r.j.files.entries), lambda k: lower(k) LIKE '%%.pdf')[1]")
  lic <- sprintf("lower(%s.rights[1].id)", m)
  sel <- if (versions == "latest") {
    "QUALIFY row_number() OVER (PARTITION BY conceptrecid
       ORDER BY is_latest DESC NULLS LAST, version_index DESC NULLS LAST, created DESC) = 1"
  } else ""
  json_text <- function(path) sprintf("CAST(json_extract(r.json, '%s') AS VARCHAR)", path)
  sprintf("
WITH v AS (
  SELECT conceptrecid, list(struct_pack(recid := id, doi := doi, version := j.metadata.version,
           publication_date := j.metadata.publication_date, created := created)
           ORDER BY version_index, created) AS versions
  FROM r GROUP BY conceptrecid
), refs AS (
  SELECT origin, list(target ORDER BY target) AS referenced_works FROM links
  WHERE link_type = 'https://openalex.org/link-types/citation' AND target_in_corpus
  GROUP BY origin
), d AS (SELECT * FROM r %s)
SELECT
  'zenodo:' || %s AS id,
  'https://doi.org/' || lower(%s) AS doi,
  %s.title AS title,
  %s.title AS display_name,
  %s AS abstract,
  TRY_CAST(%s.publication_date AS DATE) AS publication_date,
  TRY_CAST(left(%s.publication_date, 4) AS INTEGER) AS publication_year,
  coalesce(rt.type, 'other') AS type,
  lang.code AS language,
  list_transform(%s.creators, lambda c, i: struct_pack(
    author_position := CASE WHEN i = 1 THEN 'first' WHEN i = len(%s.creators) THEN 'last' ELSE 'middle' END,
    author := struct_pack(
      id := NULL::VARCHAR,
      display_name := c.person_or_org.name,
      orcid := 'https://orcid.org/' || list_filter(c.person_or_org.identifiers, lambda x: lower(x.scheme) = 'orcid')[1].identifier),
    institutions := list_transform(list_filter(c.affiliations, lambda a: a.id IS NOT NULL), lambda a: struct_pack(
      id := NULL::VARCHAR, display_name := a.name, ror := 'https://ror.org/' || a.id)),
    raw_author_name := c.person_or_org.name,
    raw_affiliation_strings := list_transform(c.affiliations, lambda a: a.name))) AS authorships,
  struct_pack(
    source := struct_pack(id := NULL::VARCHAR, display_name := 'Zenodo', type := 'repository'),
    landing_page_url := %s,
    pdf_url := CASE WHEN %s AND %s IS NOT NULL THEN %s || '/files/' || replace(%s, ' ', '%%20') END,
    license := CASE WHEN %s LIKE 'cc0%%' THEN 'public-domain'
                    WHEN %s LIKE 'cc-by%%' THEN regexp_extract(%s, '^(cc-by(-nc)?(-sa|-nd)?)', 1)
                    ELSE %s END,
    is_oa := %s) AS primary_location,
  struct_pack(is_oa := %s, oa_status := CASE WHEN %s THEN 'green' ELSE 'closed' END,
              oa_url := CASE WHEN %s THEN %s END) AS open_access,
  list_transform(%s.subjects, lambda s: struct_pack(id := NULL::VARCHAR, display_name := s.subject)) AS keywords,
  list_transform(list_filter(%s.funding, lambda f: f.funder.name IS NOT NULL OR f.funder.id IS NOT NULL),
    lambda f: struct_pack(id := NULL::VARCHAR, display_name := f.funder.name,
                          ror := 'https://ror.org/' || f.funder.id)) AS funders,
  list_transform(list_filter(%s.funding, lambda f: f.award.number IS NOT NULL OR f.award.title.en IS NOT NULL),
    lambda f: struct_pack(id := NULL::VARCHAR, display_name := f.award.title.en,
                          funder_award_id := f.award.number, funder_display_name := f.funder.name)) AS awards,
  struct_pack(volume := r.j.custom_fields.\"journal:journal\".volume,
              issue := r.j.custom_fields.\"journal:journal\".issue,
              first_page := nullif(split_part(r.j.custom_fields.\"journal:journal\".pages, '-', 1), ''),
              last_page := nullif(split_part(r.j.custom_fields.\"journal:journal\".pages, '-', 2), '')) AS biblio,
  coalesce(refs.referenced_works, []::VARCHAR[]) AS referenced_works,
  struct_pack(doi := 'https://doi.org/' || lower(%s),
              zenodo := 'https://zenodo.org/records/' || %s) AS ids,
  left(r.created, 10) AS created_date,
  r.updated AS updated_date,
  r.id AS zenodo_recid,
  r.conceptrecid AS zenodo_conceptrecid,
  r.doi AS zenodo_record_doi,
  r.conceptdoi AS zenodo_concept_doi,
  %s.version AS zenodo_version,
  v.versions AS zenodo_versions,
  %s.resource_type.id AS zenodo_resource_type,
  %s.publisher AS zenodo_publisher,
  %s.rights[1].id AS zenodo_license,
  r.j.access.status AS zenodo_access_status,
  list_transform(r.j.parent.communities.entries, lambda e: e.slug) AS zenodo_communities,
  [%s] AS zenodo_sources,
  list_transform(%s.related_identifiers, lambda x: struct_pack(identifier := x.identifier, scheme := x.scheme,
    relation := x.relation_type.id, resource_type := x.resource_type.id)) AS zenodo_related,
  list_transform(%s.references, lambda x: x.reference) AS zenodo_references,
  list_transform(map_values(r.j.files.entries), lambda f: struct_pack(key := f.key, size := f.size,
    checksum := f.checksum, mimetype := f.mimetype,
    url := %s || '/files/' || replace(f.key, ' ', '%%20'))) AS zenodo_files,
  %s AS zenodo_contributors,
  %s AS zenodo_locations,
  %s AS zenodo_dates,
  %s AS zenodo_additional_descriptions,
  %s AS zenodo_identifiers,
  %s AS zenodo_swh%s
FROM d AS r
LEFT JOIN v USING (conceptrecid)
LEFT JOIN refs ON refs.origin = 'zenodo:' || r.conceptrecid
LEFT JOIN resource_types rt ON rt.resource_type = r.j.metadata.resource_type.id
LEFT JOIN languages lang ON lang.code3 = r.j.metadata.languages[1].id
ORDER BY id",
    sel,
    if (versions == "latest") "r.conceptrecid" else "r.id",
    if (versions == "latest") "coalesce(nullif(r.conceptdoi, ''), r.doi)" else "r.doi",
    m, m, sql_strip_html(paste0(m, ".description")), m, m,
    m, m,
    record_url, files_public, pdf, record_url, pdf,
    lic, lic, lic, lic, files_public,
    files_public, files_public, files_public, record_url,
    m, m, m,
    if (versions == "latest") "coalesce(nullif(r.conceptdoi, ''), r.doi)" else "r.doi",
    if (versions == "latest") "r.conceptrecid" else "r.id",
    m, m, m, m,
    sprintf("'%s'", name),
    m, m, record_url,
    json_text("$.metadata.contributors"), json_text("$.metadata.locations"),
    json_text("$.metadata.dates"), json_text("$.metadata.additional_descriptions"),
    json_text("$.metadata.identifiers"), json_text("$.swh"),
    if (stats) ",\n  r.j.stats AS zenodo_stats,\n  r.fetched AS zenodo_stats_date" else "")
}
