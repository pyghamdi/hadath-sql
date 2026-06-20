-- #########################################################
-- hsql_create_tf_idf_tbl runtime evaluation
-- #########################################################
--
-- Builds a 100K-row corpus (~1k real English words/row) via Python, then benchmarks
-- hsql_create_tf_idf_tbl on 10K, 20K, ... 100K documents.
--
-- Usage (from repository root):
--   PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5432 -U postgres \
--     -d hadathdb -f tf_idf/eval/eval.sql
--
-- With options (note the space before each line-continuation backslash):
--   PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5432 -U postgres \
--     -d hadathdb \
--     -v words_per_row=100 \
--     -v recreate_data=false \
--     -f tf_idf/eval/eval.sql
--
-- Optional psql variables:
--   source_tbl        full benchmark corpus table name    (default: tfidf_eval_data)
--   input_view        per-run view over source_tbl        (default: tfidf_eval_input)
--   doc_id_col        document id column                  (default: doc_id)
--   text_col          text column                       (default: txt)
--   max_rows          total documents to generate       (default: 100000)
--   step_rows         row-count increment per benchmark   (default: 10000)
--   words_per_row     words per document (Python)       (default: 1000)
--   texts_file        source texts file for Python      (default: dataset/1000_long.txt)
--   recreate_data     regenerate corpus via Python (t/f)  (default: true)
--   db_host           database host for Python            (default: 127.0.0.1)
--   db_port           database port for Python            (default: 5432)
--   db_name           database name for Python            (default: hadathdb)
--   db_user           database user for Python            (default: postgres)
--   db_password       database password for Python        (default: postgres)

\set ON_ERROR_STOP on
-- SET client_min_messages TO WARNING;

\if :{?source_tbl}
\else
\set source_tbl tfidf_eval_data
\endif

\if :{?input_view}
\else
\set input_view tfidf_eval_input
\endif

\if :{?doc_id_col}
\else
\set doc_id_col doc_id
\endif

\if :{?text_col}
\else
\set text_col txt
\endif

\if :{?max_rows}
\else
\set max_rows 100000
\endif

\if :{?step_rows}
\else
\set step_rows 10000
\endif

\if :{?words_per_row}
\else
\set words_per_row 1000
\endif

\if :{?texts_file}
\else
\set texts_file dataset/1000_long.txt
\endif

\if :{?recreate_data}
\else
\set recreate_data true
\endif

\if :{?db_host}
\else
\set db_host 127.0.0.1
\endif

\if :{?db_port}
\else
\set db_port 5432
\endif

\if :{?db_name}
\else
\set db_name hadathdb
\endif

\if :{?db_user}
\else
\set db_user postgres
\endif

\if :{?db_password}
\else
\set db_password postgres
\endif

\echo '>>> hsql_create_tf_idf_tbl benchmark settings'
\echo '    source_tbl=' :source_tbl ', input_view=' :input_view
\echo '    doc_id_col=' :doc_id_col ', text_col=' :text_col
\echo '    max_rows=' :max_rows ', step_rows=' :step_rows ', words_per_row=' :words_per_row
\echo '    recreate_data=' :recreate_data

\ir ../tf_idf.sql

\if :recreate_data
\echo '>>> generating benchmark corpus via Python'
\setenv PGHOST :db_host
\setenv PGPORT :db_port
\setenv PGUSER :db_user
\setenv PGPASSWORD :db_password
\setenv PGDATABASE :db_name
\setenv TFIDF_EVAL_TABLE :source_tbl
\setenv TFIDF_EVAL_ROWS :max_rows
\setenv TFIDF_EVAL_WORDS :words_per_row
\setenv TFIDF_EVAL_TEXTS_FILE :texts_file
\! python3 tf_idf/eval/generate_eval_data.py
\else
\echo '>>> reusing existing benchmark corpus:' :source_tbl
SELECT
    COUNT(*) AS row_count,
    MIN(array_length(string_to_array(trim(txt), ' '), 1)) AS min_words,
    MAX(array_length(string_to_array(trim(txt), ' '), 1)) AS max_words
FROM :"source_tbl";
\endif

-- Remove legacy staging table or prior view from older eval script versions.
DROP VIEW IF EXISTS :"input_view";
DROP TABLE IF EXISTS :"input_view";

DROP TABLE IF EXISTS tfidf_eval_results;

CREATE TABLE tfidf_eval_results (
    row_limit integer NOT NULL,
    elapsed_ms numeric(14, 3) NOT NULL,
    output_rows bigint NOT NULL
);

DO $$
BEGIN
    EXECUTE $fn$
        DROP FUNCTION IF EXISTS tfidf_eval_runtime(text, text, text, text, integer, integer);
        DROP FUNCTION IF EXISTS hsql_tfidf_eval_runtime(text, text, text, text, integer, integer);

        CREATE OR REPLACE FUNCTION hsql_tfidf_eval_runtime(
            p_source_tbl text,
            p_input_view text,
            p_doc_id_col text,
            p_text_col text,
            p_max_rows integer,
            p_step_rows integer
        )
        RETURNS void
        LANGUAGE plpgsql
        AS $body$
        DECLARE
            v_row_limit integer;
            v_started_at timestamptz;
            v_elapsed_ms numeric(14, 3);
            v_output_rows bigint;
            v_output_tbl text := 'tfidf_eval_out';
        BEGIN
            IF p_max_rows < 1 THEN
                RAISE EXCEPTION 'max_rows must be >= 1, got %', p_max_rows;
            END IF;

            IF p_step_rows < 1 THEN
                RAISE EXCEPTION 'step_rows must be >= 1, got %', p_step_rows;
            END IF;

            IF p_max_rows % p_step_rows <> 0 THEN
                RAISE EXCEPTION 'max_rows (%) must be divisible by step_rows (%)',
                    p_max_rows, p_step_rows;
            END IF;

            FOR v_row_limit IN
                SELECT generate_series(p_step_rows, p_max_rows, p_step_rows)
            LOOP
                -- Limit rows via a view; hsql_create_tf_idf_tbl reads the whole input relation.
                EXECUTE format(
                    'CREATE OR REPLACE VIEW %I AS
                     SELECT %I, %I
                     FROM %I
                     WHERE %I <= %s',
                    p_input_view,
                    p_doc_id_col,
                    p_text_col,
                    p_source_tbl,
                    p_doc_id_col,
                    v_row_limit
                );

                v_started_at := clock_timestamp();
                PERFORM hsql_create_tf_idf_tbl(
                    p_input_view,
                    p_doc_id_col,
                    p_text_col,
                    v_output_tbl,
                    TRUE
                );
                v_elapsed_ms :=
                    EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at)) * 1000.0;

                EXECUTE format('SELECT COUNT(*)::bigint FROM %I', v_output_tbl)
                INTO v_output_rows;

                EXECUTE format('DROP TABLE IF EXISTS %I', v_output_tbl);

                INSERT INTO tfidf_eval_results (
                    row_limit,
                    elapsed_ms,
                    output_rows
                )
                VALUES (
                    v_row_limit,
                    v_elapsed_ms,
                    v_output_rows
                );

                RAISE NOTICE 'hsql_create_tf_idf_tbl on % docs: % ms (% output rows)',
                    v_row_limit,
                    ROUND(v_elapsed_ms, 3),
                    v_output_rows;
            END LOOP;

            EXECUTE format('DROP VIEW IF EXISTS %I', p_input_view);
        END;
        $body$;
    $fn$;
END;
$$;

SELECT hsql_tfidf_eval_runtime(
    :'source_tbl',
    :'input_view',
    :'doc_id_col',
    :'text_col',
    :'max_rows'::integer,
    :'step_rows'::integer
);

\echo '>>> per-run timings'
SELECT
    row_limit,
    ROUND(elapsed_ms, 3) AS elapsed_ms,
    ROUND(elapsed_ms / row_limit, 6) AS ms_per_doc,
    output_rows
FROM tfidf_eval_results
ORDER BY row_limit;

\echo '>>> summary'
SELECT
    COUNT(*) AS runs,
    MIN(row_limit) AS min_row_limit,
    MAX(row_limit) AS max_row_limit,
    ROUND(MIN(elapsed_ms), 3) AS min_elapsed_ms,
    ROUND(AVG(elapsed_ms), 3) AS avg_elapsed_ms,
    ROUND(MAX(elapsed_ms), 3) AS max_elapsed_ms,
    ROUND(MAX(elapsed_ms) / NULLIF(MIN(elapsed_ms), 0), 3) AS max_over_min_ratio
FROM tfidf_eval_results;
