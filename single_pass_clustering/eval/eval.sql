-- #########################################################
-- hsql_single_pass_clustering runtime evaluation
-- #########################################################
--
-- Builds a 10K-row corpus (~1k real English words/row) via Python, then benchmarks
-- hsql_single_pass_clustering on 1K, 2K, ... 10K documents.
--
-- Usage (from repository root):
--   PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5432 -U postgres \
--     -d hadathdb -f single_pass_clustering/eval/eval.sql
--
-- With options (note the space before each line-continuation backslash):
--   PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5432 -U postgres \
--     -d hadathdb \
--     -v words_per_row=100 \
--     -v recreate_data=false \
--     -f single_pass_clustering/eval/eval.sql
--
-- Optional psql variables:
--   source_tbl        full benchmark corpus table name    (default: sp_eval_data)
--   input_view        per-run view over source_tbl        (default: sp_eval_input)
--   doc_id_col        document id column                  (default: doc_id)
--   text_col          text column                       (default: txt)
--   ts_col            timestamp column for doc order      (default: ts)
--   threshold         clustering similarity threshold     (default: 0.7)
--   max_rows          total documents to generate       (default: 10000)
--   step_rows         row-count increment per benchmark   (default: 1000)
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
\set source_tbl sp_eval_data
\endif

\if :{?input_view}
\else
\set input_view sp_eval_input
\endif

\if :{?doc_id_col}
\else
\set doc_id_col doc_id
\endif

\if :{?text_col}
\else
\set text_col txt
\endif

\if :{?ts_col}
\else
\set ts_col ts
\endif

\if :{?threshold}
\else
\set threshold 0.7
\endif

\if :{?max_rows}
\else
\set max_rows 10000
\endif

\if :{?step_rows}
\else
\set step_rows 1000
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

\echo '>>> hsql_single_pass_clustering benchmark settings'
\echo '    source_tbl=' :source_tbl ', input_view=' :input_view
\echo '    doc_id_col=' :doc_id_col ', text_col=' :text_col ', ts_col=' :ts_col
\echo '    threshold=' :threshold
\echo '    max_rows=' :max_rows ', step_rows=' :step_rows ', words_per_row=' :words_per_row
\echo '    recreate_data=' :recreate_data

\ir ../../util/table_utils.sql
\ir ../../tf_idf/tf_idf.sql
\ir ../sp_clustering.sql

\if :recreate_data
\echo '>>> generating benchmark corpus via Python'
\setenv PGHOST :db_host
\setenv PGPORT :db_port
\setenv PGUSER :db_user
\setenv PGPASSWORD :db_password
\setenv PGDATABASE :db_name
\setenv SP_EVAL_TABLE :source_tbl
\setenv SP_EVAL_ROWS :max_rows
\setenv SP_EVAL_WORDS :words_per_row
\setenv SP_EVAL_TEXTS_FILE :texts_file
\! python3 single_pass_clustering/eval/generate_eval_data.py
\else
\echo '>>> reusing existing benchmark corpus:' :source_tbl
SELECT
    COUNT(*) AS row_count,
    MIN(array_length(string_to_array(trim(txt), ' '), 1)) AS min_words,
    MAX(array_length(string_to_array(trim(txt), ' '), 1)) AS max_words,
    MIN(ts) AS min_ts,
    MAX(ts) AS max_ts
FROM :"source_tbl";
\endif

DROP VIEW IF EXISTS :"input_view";
DROP TABLE IF EXISTS :"input_view";

DROP TABLE IF EXISTS sp_eval_results;

CREATE TABLE sp_eval_results (
    row_limit integer NOT NULL,
    elapsed_ms numeric(14, 3) NOT NULL,
    cluster_count bigint NOT NULL,
    assignment_count bigint NOT NULL,
    tfidf_rows bigint NOT NULL
);

DO $$
BEGIN
    EXECUTE $fn$
        DROP FUNCTION IF EXISTS sp_eval_runtime(
            text, text, text, text, text, float, integer, integer
        );

        CREATE OR REPLACE FUNCTION sp_eval_runtime(
            p_source_tbl text,
            p_input_view text,
            p_doc_id_col text,
            p_text_col text,
            p_ts_col text,
            p_threshold float,
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
            v_cluster_count bigint;
            v_assignment_count bigint;
            v_tfidf_rows bigint;
            v_output_tbl text := 'sp_eval_out';
            v_centroid_tbl text;
            v_assignments_tbl text;
            v_tfidf_tbl text;
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

            v_centroid_tbl := v_output_tbl || '_centroid';
            v_assignments_tbl := v_output_tbl || '_cluster_assignments';
            v_tfidf_tbl := v_output_tbl || '_tfidf';

            FOR v_row_limit IN
                SELECT generate_series(p_step_rows, p_max_rows, p_step_rows)
            LOOP
                EXECUTE format(
                    'CREATE OR REPLACE VIEW %I AS
                     SELECT %I, %I, %I
                     FROM %I
                     WHERE %I <= %s',
                    p_input_view,
                    p_doc_id_col,
                    p_text_col,
                    p_ts_col,
                    p_source_tbl,
                    p_doc_id_col,
                    v_row_limit
                );

                v_started_at := clock_timestamp();
                PERFORM hsql_single_pass_clustering(
                    p_input_view,
                    p_doc_id_col,
                    p_text_col,
                    p_ts_col,
                    v_output_tbl,
                    p_threshold,
                    TRUE
                );
                v_elapsed_ms :=
                    EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at)) * 1000.0;

                EXECUTE format('SELECT COUNT(*)::bigint FROM %I', v_output_tbl)
                INTO v_cluster_count;
                EXECUTE format('SELECT COUNT(*)::bigint FROM %I', v_assignments_tbl)
                INTO v_assignment_count;
                EXECUTE format('SELECT COUNT(*)::bigint FROM %I', v_tfidf_tbl)
                INTO v_tfidf_rows;

                EXECUTE format(
                    'DROP TABLE IF EXISTS %I, %I, %I, %I CASCADE',
                    v_output_tbl,
                    v_centroid_tbl,
                    v_assignments_tbl,
                    v_tfidf_tbl
                );

                INSERT INTO sp_eval_results (
                    row_limit,
                    elapsed_ms,
                    cluster_count,
                    assignment_count,
                    tfidf_rows
                )
                VALUES (
                    v_row_limit,
                    v_elapsed_ms,
                    v_cluster_count,
                    v_assignment_count,
                    v_tfidf_rows
                );

                RAISE NOTICE 'hsql_single_pass_clustering on % docs: % ms (% clusters, % assignments, % tfidf rows)',
                    v_row_limit,
                    ROUND(v_elapsed_ms, 3),
                    v_cluster_count,
                    v_assignment_count,
                    v_tfidf_rows;
            END LOOP;

            EXECUTE format('DROP VIEW IF EXISTS %I', p_input_view);
        END;
        $body$;
    $fn$;
END;
$$;

SELECT sp_eval_runtime(
    :'source_tbl',
    :'input_view',
    :'doc_id_col',
    :'text_col',
    :'ts_col',
    :'threshold'::float,
    :'max_rows'::integer,
    :'step_rows'::integer
);

\echo '>>> per-run timings'
SELECT
    row_limit,
    ROUND(elapsed_ms, 3) AS elapsed_ms,
    ROUND(elapsed_ms / row_limit, 6) AS ms_per_doc,
    cluster_count,
    assignment_count,
    tfidf_rows
FROM sp_eval_results
ORDER BY row_limit;

\echo '>>> summary'
SELECT
    COUNT(*) AS runs,
    MIN(row_limit) AS min_row_limit,
    MAX(row_limit) AS max_row_limit,
    ROUND(MIN(elapsed_ms), 3) AS min_elapsed_ms,
    ROUND(AVG(elapsed_ms), 3) AS avg_elapsed_ms,
    ROUND(MAX(elapsed_ms), 3) AS max_elapsed_ms,
    ROUND(MAX(elapsed_ms) / NULLIF(MIN(elapsed_ms), 0), 3) AS max_over_min_ratio,
    MIN(cluster_count) AS min_clusters,
    MAX(cluster_count) AS max_clusters
FROM sp_eval_results;
