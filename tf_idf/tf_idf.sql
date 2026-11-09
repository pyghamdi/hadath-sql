/*
################################################################################
TF-IDF Utilities (tf_idf.sql)
################################################################################
This script defines reusable PostgreSQL UDFs for:
  - tokenizing text into `(term, count)` pairs (`hsql_term_counts`)
  - building a full TF-IDF output table (`hsql_create_tf_idf_tbl`)

Text is preprocessed with PostgreSQL full-text search, `to_tsvector('english', ...)`,
which lowercases the text, removes English stop words, and stems the remaining words.
The output table created by `hsql_create_tf_idf_tbl` has the schema
  `(doc_id INTEGER, term TEXT, weight FLOAT)`.

Examples:
  -- Terms of one text: returns (fire, 2) and (downtown, 1)
  SELECT * FROM hsql_term_counts('Fires and a fire downtown');

  -- Build the table docs_tfidf from docs(doc_id, txt), replacing it if it exists
  SELECT hsql_create_tf_idf_tbl('docs', 'doc_id', 'txt', 'docs_tfidf', TRUE);
  SELECT * FROM docs_tfidf ORDER BY doc_id, weight DESC;
################################################################################
*/


/* ################################################################################
hsql_term_counts
--------------------------------------------------------------------------------
Converts one text value into its terms and the number of times each term occurs.
Uses PostgreSQL full-text tokenization (`to_tsvector`) with the English
configuration, so stop words are removed and the remaining words are stemmed.

Parameters:
  input - Document text to tokenize (NULL is treated as empty text), or
  tsv   - its terms, as returned by to_tsvector('english', input)

Returns: TABLE(term text, count integer)

Notes:
  - Output has one row per distinct term of `input`
  - Call it in FROM, for example with a lateral join:
      SELECT d.doc_id, t.term, t.count
      FROM docs AS d CROSS JOIN LATERAL hsql_term_counts(d.txt) AS t;
  - Marked `PARALLEL SAFE`; the text version is `STABLE` (to_tsvector depends on
    the text search configuration), the tsvector version `IMMUTABLE`
  - The terms are read from the tsvector with unnest(tsvector), which returns
    each lexeme with the array of its positions; the count of a term is the
    length of that array. (to_tsvector keeps at most 255 positions per lexeme,
    so a term that occurs more than 255 times in one text is counted as 255.)
################################################################################ */
CREATE OR REPLACE FUNCTION hsql_term_counts(
    tsv tsvector
)
RETURNS TABLE(term text, count integer)
AS $$
    SELECT
        lexeme AS term,
        array_length(positions, 1) AS count
    FROM unnest(tsv)
$$ LANGUAGE SQL IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION hsql_term_counts(
    input text
)
RETURNS TABLE(term text, count integer)
AS $$
    SELECT * FROM hsql_term_counts(to_tsvector('english', coalesce(input, '')))
$$ LANGUAGE SQL STABLE PARALLEL SAFE;


/* ################################################################################
hsql_create_tf_idf_tbl
--------------------------------------------------------------------------------
Builds a TF-IDF output table from a source document table.

Parameters:
  input_tbl             - Name of the source table, one row per document
  doc_id_col            - Name of the column with the unique document id (INTEGER)
  text_col              - Name of the column with the document text
  output_tbl            - Name of the table to create, `(doc_id, term, weight)`
  overwrite_output_tbl  - If TRUE, drop and recreate the output table when it
                          already exists; if FALSE (the default), raise an error
  unlogged              - If TRUE (the default), create the output table as UNLOGGED:
                          it is not written to the write-ahead log, which makes
                          building it much faster, but it is emptied after a crash
                          and not replicated to standby servers. The table holds
                          derived data that can be rebuilt from input_tbl. Pass
                          FALSE for a regular (logged) table.

Example:
  SELECT hsql_create_tf_idf_tbl('docs', 'doc_id', 'txt', 'docs_tfidf', TRUE);

Steps (one CREATE TABLE AS statement):
  1. Convert each document to a tsvector and extract its terms and counts via
     hsql_term_counts
  2. Build TF-per-document and DF-per-term aggregates using CTEs
  3. Compute the TF-IDF weights into the output table

Parallel execution:
  to_tsvector can run in parallel workers. How many PostgreSQL uses is set by the
  configuration, not by this function: max_parallel_workers_per_gather (default
  2), max_parallel_workers (default 8), max_worker_processes (default 8; needs a
  restart), and the size of input_tbl, which the parallel_workers storage
  parameter overrides (ALTER TABLE ... SET (parallel_workers = n)). The function
  sets parallel_tuple_cost = 0 while it runs, since the planner underestimates the
  cost of to_tsvector and would otherwise not use the workers.

Returns:
  void

Formula:
  weight = (term_count_in_doc / total_terms_in_doc) * LOG(total_docs / docs_with_term)
  LOG is the base-10 logarithm, computed in double precision (FLOAT): computing
  it in NUMERIC, as LOG(1.0 * total_docs / df) would, made the query several
  times slower, since it is evaluated once per (document, term) row.
  A term that occurs in every document gets weight 0.
################################################################################ */
CREATE OR REPLACE FUNCTION hsql_create_tf_idf_tbl(
    input_tbl text,
    doc_id_col text,
    text_col text,
    output_tbl text,
    overwrite_output_tbl boolean DEFAULT FALSE,
    unlogged boolean DEFAULT TRUE
)
RETURNS VOID AS $$
DECLARE
    output_tbl_exists boolean := FALSE;
    total_docs integer := 0;
BEGIN
    -- Check whether the output table already exists.
    EXECUTE format(
        'SELECT EXISTS(
            SELECT 1 FROM information_schema.tables WHERE table_name = %L)', output_tbl) INTO output_tbl_exists;

    IF output_tbl_exists THEN
        IF overwrite_output_tbl THEN
            RAISE NOTICE 'Output table % already exists. Dropping it.', output_tbl;
            EXECUTE format('DROP TABLE %I', output_tbl);
        ELSE
            RAISE EXCEPTION 'Output table % already exists. Use a different output table name or set overwrite_output_tbl=TRUE to overwrite the existing table.', output_tbl;
        END IF;
    END IF;

    -- Get corpus size (total_docs), used in the IDF calculation.
    EXECUTE format('SELECT COUNT(*) FROM %I', input_tbl) INTO total_docs;
    RAISE NOTICE 'Building TF-IDF table % from % documents of %', output_tbl, total_docs, input_tbl;

    -- Build the table in one CREATE TABLE AS statement (an INSERT ... SELECT is never
    -- run in parallel). The text of each document is converted to a tsvector in a
    -- subquery with OFFSET 0, which the planner does not merge into the outer query,
    -- so that to_tsvector, the most expensive step, can run in parallel workers.
    EXECUTE format(
        'CREATE %s TABLE %I AS
         WITH doc_term_counts AS (
             SELECT
                 src.doc_id,
                 terms.term,
                 terms.term_count
             FROM (
                 SELECT %I AS doc_id, to_tsvector(''english'', coalesce(%I, '''')) AS tsv
                 FROM %I
                 OFFSET 0
             ) AS src
             CROSS JOIN LATERAL hsql_term_counts(src.tsv) AS terms(term, term_count)
         ),
         tf_per_doc AS (
             SELECT doc_id, SUM(term_count) AS tf
             FROM doc_term_counts
             GROUP BY doc_id
         ),
         df_per_term AS (
             SELECT term, COUNT(*) AS df
             FROM doc_term_counts
             GROUP BY term
         )
         SELECT
             dtc.doc_id::INTEGER AS doc_id,
             dtc.term::TEXT AS term,
             ((dtc.term_count::FLOAT / tf.tf) * LOG(%s::FLOAT / df.df))::FLOAT AS weight
         FROM doc_term_counts AS dtc
         JOIN tf_per_doc AS tf ON dtc.doc_id = tf.doc_id
         JOIN df_per_term AS df ON dtc.term = df.term',
        CASE WHEN unlogged THEN 'UNLOGGED' ELSE '' END,
        output_tbl,
        doc_id_col,
        text_col,
        input_tbl,
        total_docs
    );
END;
$$ LANGUAGE plpgsql
-- The planner underestimates the cost of to_tsvector, so with the default
-- parallel_tuple_cost it judges that sending the tsvectors from parallel workers
-- costs more than computing them in one process, and never uses the workers.
-- This setting applies only while the function runs.
SET parallel_tuple_cost = 0;
