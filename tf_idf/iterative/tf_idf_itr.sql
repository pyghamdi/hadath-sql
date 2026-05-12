/* ################################################################################
hsql_create_tf_idf_tbl_itr
--------------------------------------------------------------------------------
Builds a TF-IDF output table from a source document table using iterative
processing and temporary helper tables.

Requires:
  - hsql_process_text(input text), defined in ../tf_idf.sql

Parameters:
  input_tbl             - Source corpus table
  text_col              - Column name containing document text
  doc_id_col            - Column name for unique document id
  output_tbl            - Output table name `(doc_id, term, weight)`
  overwrite_output_tbl  - If TRUE, drop/recreate output table when it exists

Approach:
  1. Iterate over source rows and insert `(doc_id, term, freq)` into temp table
  2. Aggregate temp tables for per-document TF and per-term DF
  3. Compute and insert TF-IDF weights into output table

Returns:
  void

Formula:
  weight = (term_count_in_doc / total_terms_in_doc) * LOG(total_docs / docs_with_term)
################################################################################ */

DROP FUNCTION IF EXISTS hsql_create_tf_idf_tbl_itr(text, text, text, text, boolean) CASCADE;

CREATE OR REPLACE FUNCTION hsql_create_tf_idf_tbl_itr(
    input_tbl text,
    text_col text,
    doc_id_col text,
    output_tbl text,
    overwrite_output_tbl boolean DEFAULT FALSE
) RETURNS VOID AS $$
DECLARE
    output_tbl_exists boolean := FALSE;
    total_docs integer := 0;
    doc_txt text;
    doc_id integer;
    term text;
    count integer;
    docid_term_count_tbl text := 'docid_term_count_tbl_' || substr(md5(random()::text), 1, 12);
    tf_tbl text := 'tf_tbl_' || substr(md5(random()::text), 1, 12);
    df_tbl text := 'df_tbl_' || substr(md5(random()::text), 1, 12);
BEGIN
    -- Check if the output table exists.
    RAISE NOTICE 'Checking if output table % exists', output_tbl;
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

    -- Create output and temporary helper tables.
    RAISE NOTICE 'Creating output table %', output_tbl;
    EXECUTE format('CREATE TABLE %I (doc_id INTEGER, term TEXT, weight FLOAT)', output_tbl);

    RAISE NOTICE 'Creating temporary (doc_id, term, count) table %', docid_term_count_tbl;
    EXECUTE format('CREATE TABLE %I (doc_id INTEGER, term TEXT, count INTEGER)', docid_term_count_tbl);

    RAISE NOTICE 'Creating temporary (doc_id, tf) table %', tf_tbl;
    EXECUTE format(
        'CREATE TABLE %I (doc_id INTEGER PRIMARY KEY, tf INTEGER NOT NULL)',
        tf_tbl
    );

    RAISE NOTICE 'Creating temporary (term, df) table %', df_tbl;
    EXECUTE format(
        'CREATE TABLE %I (term TEXT PRIMARY KEY, df INTEGER NOT NULL)',
        df_tbl
    );

    -- First iteration: compute term counts per document and document frequency df for each term.
    FOR doc_txt, doc_id IN EXECUTE format(
        'SELECT %I AS text, %I AS doc_id FROM %I',
        text_col,
        doc_id_col,
        input_tbl
    )
    LOOP
        EXECUTE format(
            'INSERT INTO %I (doc_id, term, count)
             SELECT $1::integer AS doc_id, (terms_count).term, (terms_count).count
             FROM (
                 SELECT hsql_process_text($2::text) AS terms_count
             ) AS src',
            docid_term_count_tbl
        ) USING doc_id, doc_txt;

        -- Update document frequency per term.
        FOR term IN EXECUTE format(
            'SELECT DISTINCT term FROM %I WHERE doc_id = $1',
            docid_term_count_tbl
        )
        USING doc_id
        LOOP
            EXECUTE format(
                'INSERT INTO %I (term, df) VALUES ($1, 1) ON CONFLICT (term) DO UPDATE SET df = %I.df + 1',
                df_tbl,
                df_tbl
            ) USING term;
        END LOOP;
    END LOOP;

    -- Get corpus size (total_docs), used in the IDF calculation.
    EXECUTE format('SELECT COUNT(*) FROM %I', input_tbl) INTO total_docs;
    RAISE NOTICE 'Number of documents in input table % is %', input_tbl, total_docs;

    -- Second iteration: compute the tf-idf weight for each term in each document.
    FOR doc_id, term, count IN EXECUTE format(
        'SELECT doc_id, term, count FROM %I',
        docid_term_count_tbl
    )
    LOOP
        EXECUTE format(
            'INSERT INTO %I (doc_id, term, weight)
             SELECT $1, $2,
                    ($3::FLOAT / NULLIF(doc_tot.tf, 0)) * LOG(1.0 * $4 / df.df) AS weight
             FROM %I AS df
             JOIN (
                 SELECT SUM(dtc.count)::double precision AS tf
                 FROM %I AS dtc
                 WHERE dtc.doc_id = $1
             ) AS doc_tot ON TRUE
             WHERE df.term = $2',
            output_tbl,
            df_tbl,
            docid_term_count_tbl
        ) USING doc_id, term, count, total_docs;
    END LOOP;

    -- Drop temporary tables.
    EXECUTE format('DROP TABLE %I', tf_tbl);
    EXECUTE format('DROP TABLE %I', df_tbl);

    RAISE NOTICE 'Inserted TF-IDF rows into output table %', output_tbl;
END;
$$
LANGUAGE plpgsql;
