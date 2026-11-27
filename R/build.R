# Builds the works corpus and the link table of a source from its stored records (internal:
# zenodo_fetch() runs it after each download; see its help for what is written). `NULL`
# settings: as in raw/<name>/_query.json. Returns, invisibly, the corpus and link folders.
zenodo_build <- function(project_folder, name = "zenodo", versions = NULL, stats = NULL,
                         parquet_split = NULL) {
  check_name(name)
  raw <- file.path(project_folder, "raw", name)
  if (!length(stored_files(raw))) {
    stop("No records for `", name, "` in ", raw, "; run zenodo_fetch() first.", call. = FALSE)
  }
  rec_file <- file.path(raw, "_query.json")
  rec <- if (file.exists(rec_file)) jsonlite::read_json(rec_file, simplifyVector = TRUE)
  versions <- match.arg(versions %||% rec$build$versions %||% "latest", c("latest", "all"))
  stats <- isTRUE(stats %||% rec$build$stats)
  split <- check_split(parquet_split %||% rec$build$parquet_split %||% "none")
  build <- list(versions = versions, stats = stats, parquet_split = split)
  if (!is.null(rec) && !identical(rec$build, build)) {
    rec$build <- build
    write_query_record(rec, raw)
  }

  con <- zenodo_duckdb()
  tmp <- paste0(raw, ".build")
  unlink(tmp, recursive = TRUE)
  dir.create(file.path(tmp, "works"), recursive = TRUE)
  on.exit({
    DBI::dbDisconnect(con, shutdown = TRUE)
    unlink(tmp, recursive = TRUE)
  })
  DBI::dbExecute(con, sprintf("SET temp_directory = %s", sql_str(file.path(tmp, "spill"))))
  for (t in c("languages", "resource_types", "relations")) {
    d <- utils::read.csv(system.file("extdata", paste0(t, ".csv"), package = "openalexImportZenodo"),
                         stringsAsFactors = FALSE, na.strings = "")
    duckdb::duckdb_register(con, t, d)
  }
  src <- sprintf("read_parquet(%s, hive_partitioning = false, union_by_name = true)",
                 sql_files(stored_files(raw)))
  message("Building the corpus: reading versions and related identifiers")
  # 1. the small fields of every record (no JSON kept): versions, newest version, links
  DBI::dbExecute(con, sprintf(
    "CREATE TEMP TABLE rs AS SELECT id, conceptrecid, doi, created, version_index, is_latest,
       json_extract_string(json, '$.metadata.version') AS version,
       json_extract_string(json, '$.metadata.publication_date') AS publication_date,
       json_transform(json_extract(json, '$.metadata.related_identifiers'), %s) AS related
     FROM %s", sql_str(build_schema("related")), src))
  build_links(con)
  # the deposit's Zenodo creation date (first version): decides its file with a period split
  DBI::dbExecute(con, "CREATE TEMP TABLE fc AS SELECT conceptrecid, min(created) AS first_created FROM rs GROUP BY ALL")
  DBI::dbExecute(con, "CREATE TEMP TABLE v AS
    SELECT conceptrecid, list(struct_pack(recid := id, doi := doi, version := version,
             publication_date := publication_date, created := created)
             ORDER BY version_index, created) AS versions
    FROM rs GROUP BY conceptrecid")
  DBI::dbExecute(con, "CREATE TEMP TABLE refs AS
    SELECT origin, list(target ORDER BY target) AS referenced_works FROM links
    WHERE link_type = 'https://openalex.org/link-types/citation' AND target_in_corpus
    GROUP BY origin")
  DBI::dbExecute(con, sprintf("CREATE TEMP TABLE sel AS SELECT id, created FROM rs %s",
    if (versions == "latest") "QUALIFY row_number() OVER (PARTITION BY conceptrecid
       ORDER BY is_latest DESC NULLS LAST, version_index DESC NULLS LAST, created DESC) = 1" else ""))

  # 2. the chosen records in batches by `created`, each mapped to a temporary file
  part <- if (split %in% split_periods) sql_label(split, "fc.first_created") else "NULL"
  lo <- unique(DBI::dbGetQuery(con, sprintf(
    "SELECT min(created) AS lo FROM (SELECT created, (row_number() OVER (ORDER BY created) - 1) // %d AS k
     FROM sel) GROUP BY k ORDER BY lo", as.integer(build_batch)))$lo)
  for (i in seq_along(lo)) {
    message(sprintf("Building the corpus: batch %d/%d", i, length(lo)))
    cond <- sql_in_interval(lo[i], if (i < length(lo)) lo[i + 1] else NA)
    DBI::dbExecute(con, "DROP TABLE IF EXISTS r")
    DBI::dbExecute(con, sprintf(
      "CREATE TEMP TABLE r AS SELECT s.*, json_transform(s.json, %s) AS j FROM %s s
       WHERE %s AND s.id IN (SELECT id FROM sel WHERE %s)",
      sql_str(build_schema()), src, cond, cond))
    DBI::dbExecute(con, sprintf(
      "COPY (SELECT w.*, %s AS zenodo_part FROM (%s) w JOIN fc ON fc.conceptrecid = w.zenodo_conceptrecid
             ORDER BY w.id) TO %s (FORMAT parquet, COMPRESSION zstd)",
      part, build_works_sql(name, versions, stats),
      sql_str(file.path(tmp, "works", sprintf("b%06d.parquet", i)))))
  }
  DBI::dbExecute(con, "DROP TABLE IF EXISTS r")

  # 3. split into the corpus and link files
  message("Writing the corpus and link files")
  corpus <- file.path(project_folder, "corpus", paste0("query=", name))
  links <- file.path(project_folder, "links", paste0("query=", name))
  write_split(con, sprintf("SELECT * FROM read_parquet(%s)",
                           sql_files(list.files(file.path(tmp, "works"), full.names = TRUE))),
              corpus, split, extra = file.path(raw, c("_query.json", "_query.html")))
  write_split(con, sprintf(
    "SELECT l.* EXCLUDE (dep, rank), %s AS zenodo_part FROM links l JOIN fc ON fc.conceptrecid = l.dep",
    part), links, split, "origin, target, zenodo_relation")
  write_dataset_marker(dirname(corpus))
  message(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM fc")$n, " deposits -> ", corpus)
  invisible(c(corpus = corpus, links = links))
}

# `_dataset.json` of the corpus folder (openalexPro ecosystem standard, D1-D3): who wrote it
# and how its ids look. Deterministic (no dates, no paths), so an unchanged build leaves it
# unchanged.
write_dataset_marker <- function(dir) {
  ds <- list(standard = "0.1", type = "works",
             writer = list(package = "openalexImportZenodo",
                           version = as.character(utils::packageVersion("openalexImportZenodo")),
                           prefix = "zenodo"),
             partition_keys = list("query"), id_format = "zenodo:<conceptrecid>")
  jsonlite::write_json(ds, file.path(dir, "_dataset.json"), auto_unbox = TRUE, pretty = TRUE)
}

# Records mapped per batch of the build (memory: about this many full records).
build_batch <- 50000

# Writes the rows of `sql` (with a column `zenodo_part`, dropped) to the folder `out` as one
# data.parquet, one file per part (`split` a period), or files of about `split` rows, ordered
# by `order` (NULL: in the order of `sql`).
# Written to `<out>.tmp` and swapped in only when complete. `extra` files are copied along.
write_split <- function(con, sql, out, split, order = NULL, extra = character()) {
  tmp <- paste0(out, ".tmp")
  unlink(tmp, recursive = TRUE)
  dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
  ord <- if (length(order)) paste(" ORDER BY", order) else "" # none: as given (streamed)
  sel <- sprintf("SELECT * EXCLUDE (zenodo_part) FROM (%s)%s", sql, ord)
  opts <- "FORMAT parquet, COMPRESSION zstd"
  if (identical(split, "none")) {
    dir.create(tmp)
    DBI::dbExecute(con, sprintf("COPY (%s) TO %s (%s)", sel, sql_str(file.path(tmp, "data.parquet")), opts))
  } else if (is.numeric(split)) {
    DBI::dbExecute(con, sprintf("COPY (%s) TO %s (%s, FILENAME_PATTERN 'part_{i}'%s)", sel, sql_str(tmp),
                                opts, sql_rows_per_file(split)))
  } else {
    parts <- file.path(tmp, "parts")
    dir.create(tmp)
    DBI::dbExecute(con, sprintf(
      "COPY (SELECT * FROM (%s)%s) TO %s (%s, PARTITION_BY (zenodo_part), WRITE_PARTITION_COLUMNS false)",
      sql, ord, sql_str(parts), opts))
    for (d in list.dirs(parts, recursive = FALSE)) {
      f <- list.files(d, "[.]parquet$", full.names = TRUE)
      lab <- sub("^zenodo_part=", "", basename(d))
      to <- if (length(f) == 1) paste0(lab, ".parquet") else sprintf("%s_%d.parquet", lab, seq_along(f))
      file.rename(f, file.path(tmp, to))
    }
    unlink(parts, recursive = TRUE)
  }
  if (!dir.exists(tmp)) dir.create(tmp) # no rows
  extra <- extra[file.exists(extra)]
  file.copy(extra, tmp, overwrite = TRUE)
  unlink(out, recursive = TRUE)
  if (!file.rename(tmp, out)) stop("Could not write ", out, call. = FALSE)
  out
}

# The parts of a record that are mapped, as a json_transform() structure. Missing parts
# (e.g. not stored because of `select`) become NULL.
build_schema <- function(part = c("all", "related")) {
  part <- match.arg(part)
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
  if (part == "related") s <- s$metadata$related_identifiers
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
  json_text <- function(path) sprintf("CAST(json_extract(r.json, '%s') AS VARCHAR)", path)
  sprintf("
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
FROM r
LEFT JOIN v USING (conceptrecid)
LEFT JOIN refs ON refs.origin = 'zenodo:' || r.conceptrecid
LEFT JOIN resource_types rt ON rt.resource_type = r.j.metadata.resource_type.id
LEFT JOIN languages lang ON lang.code3 = r.j.metadata.languages[1].id",
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
