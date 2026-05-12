/*
################################################################################
TF-IDF Utilities (tf_idf.sql)
################################################################################
This script defines reusable PostgreSQL UDFs for:
  - tokenizing text into `(term, count)` pairs (`hsql_process_text`)
  - building a full TF-IDF output table (`hsql_create_tf_idf_tbl`)

Expected text preprocessing is PostgreSQL English stemming via `to_tsvector('english', ...)`.
The main output table schema created by `hsql_create_tf_idf_tbl` is:
  `(doc_id INTEGER, term TEXT, weight FLOAT)`.
################################################################################
*/

-- Drop only objects defined in this script (ensures clean re-run)
DROP FUNCTION IF EXISTS hsql_process_text(text) CASCADE;
DROP FUNCTION IF EXISTS hsql_create_tf_idf_tbl(text, text, text, text, boolean) CASCADE;


/* ################################################################################
hsql_process_text
--------------------------------------------------------------------------------
Converts one text value into a normalized bag-of-terms representation.
Internally uses PostgreSQL full-text tokenization (`to_tsvector`) with
English stemming, then converts the token stream into `(term, count)` rows.

Parameters:
  input - Document text to tokenize (NULL is treated as empty text)

Returns: TABLE(term text, count integer)

Notes:
  - Output has one row per unique normalized term in `input`
  - Marked `STABLE` and `PARALLEL SAFE`
################################################################################ */
CREATE OR REPLACE FUNCTION hsql_process_text(
    input text
) 
RETURNS TABLE(term text, count integer)
AS $$ 
    SELECT 
        trim(BOTH '''' FROM split_part(ts_term, ':', 1))::text AS term,
        (length(split_part(ts_term, ':', 2)) - length(replace(split_part(ts_term, ':', 2), ',', '')) + 1)::integer AS term_count
    FROM(
        SELECT unnest(
            string_to_array(
                trim(
                    to_tsvector('english', coalesce(input, ''))::text
                ),
                ' '
            )
        ) AS ts_term
    )
$$ LANGUAGE SQL STABLE PARALLEL SAFE;



/* ################################################################################
hsql_create_tf_idf_tbl
--------------------------------------------------------------------------------
Builds a TF-IDF output table from a source document table.

Parameters:
  input_tbl             - Source corpus table
  doc_id_col            - Column name for unique document id
  text_col              - Column name containing document text
  output_tbl            - Output table name `(doc_id, term, weight)`
  overwrite_output_tbl  - If TRUE, drop/recreate output table when it exists

Steps:
  1. Process documents to extract terms and counts via hsql_process_text
  2. Build TF-per-document and DF-per-term aggregates using CTEs
  3. Compute and insert TF-IDF weight values into the output table

Returns:
  void

Formula:
  weight = (term_count_in_doc / total_terms_in_doc) * LOG(total_docs / docs_with_term)
################################################################################ */
CREATE OR REPLACE FUNCTION hsql_create_tf_idf_tbl(
    input_tbl text,
    doc_id_col text,
    text_col text,
    output_tbl text,
    overwrite_output_tbl boolean DEFAULT FALSE
)
RETURNS VOID AS $$
DECLARE
    output_tbl_exists boolean := FALSE;
    total_docs integer := 0;
BEGIN
    -- Check whether the output table already exists.
    RAISE NOTICE 'Checking if output table % exists', output_tbl;
    EXECUTE format(
        'SELECT EXISTS(
            SELECT 1 FROM information_schema.tables WHERE table_name = %L)', output_tbl) INTO output_tbl_exists;
    
    IF output_tbl_exists THEN
        RAISE NOTICE 'Output table % already exists.', output_tbl;
        -- If the output table exists, check if we should overwrite it.
        IF overwrite_output_tbl THEN
            RAISE NOTICE 'Output table % already exists. Dropping it.', output_tbl;
            EXECUTE format('DROP TABLE %I', output_tbl);
        ELSE
            RAISE EXCEPTION 'Output table % already exists. Use a different output table name or set overwrite_output_tbl=TRUE to overwrite the existing table.', output_tbl;
        END IF;
    ELSE
        RAISE NOTICE 'Output table % does not exist.', output_tbl;
    END IF;

    -- Create the output table that stores (doc_id, term, weight).
    RAISE NOTICE 'Creating output table %...', output_tbl;
    EXECUTE format('CREATE TABLE %I (doc_id INTEGER, term TEXT, weight FLOAT)', output_tbl);
    
    -- Get corpus size (total_docs), used in the IDF calculation.
    EXECUTE format('SELECT COUNT(*) FROM %I', input_tbl) INTO total_docs;
    RAISE NOTICE 'Number of documents in input table % is %', input_tbl, total_docs;
    
    RAISE NOTICE 'Building TF-IDF table %...', output_tbl;
    -- Build TF-IDF in one statement using CTEs instead of temporary tables.
    EXECUTE format(
        'INSERT INTO %I (doc_id, term, weight)
         WITH doc_term_counts AS (
             SELECT
                 src.%I AS doc_id,
                 terms.term,
                 terms.term_count
             FROM %I AS src
             CROSS JOIN LATERAL hsql_process_text(src.%I) AS terms(term, term_count)
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
             dtc.doc_id,
             dtc.term,
             (dtc.term_count::FLOAT / tf.tf) * LOG(1.0 * %s / df.df) AS weight
         FROM doc_term_counts AS dtc
         JOIN tf_per_doc AS tf ON dtc.doc_id = tf.doc_id
         JOIN df_per_term AS df ON dtc.term = df.term',
        output_tbl,
        doc_id_col,
        input_tbl,
        text_col,
        total_docs
    );
    RAISE NOTICE 'TF-IDF table % built successfully', output_tbl;
END;
$$ LANGUAGE plpgsql;
