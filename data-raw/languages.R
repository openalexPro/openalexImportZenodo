# inst/extdata/languages.csv: ISO 639-3 code (Zenodo `metadata.languages[].id`) -> ISO 639-1
# (OpenAlex `language`), for the languages that have a two-letter code.
d <- ISOcodes::ISO_639_3
d <- d[!is.na(d$Part1) & nzchar(d$Part1), c("Id", "Part1")]
names(d) <- c("code3", "code")
utils::write.csv(d[order(d$code3), ], "inst/extdata/languages.csv", row.names = FALSE)
