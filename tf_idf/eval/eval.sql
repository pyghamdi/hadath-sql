-- #########################################################
-- TF-IDF runtime evaluation script
-- Compares hsql_create_tf_idf_tbl_itr vs hsql_create_tf_idf_tbl
-- #########################################################
--
-- Usage (psql example):
--   psql -d hadathdb -f tf_idf/eval.sql \
--     -v input_tbl=test_data \
--     -v doc_id_col=doc_id \
--     -v text_col=txt \
--     -v runs=3
--
-- Optional variables:
--   input_tbl         source table name                     (default: test_data)
--   doc_id_col        document id column                    (default: doc_id)
--   text_col          text column                           (default: txt)
--   runs              benchmark repetitions per method      (default: 3)
--   itr_output_prefix iterative output table prefix         (default: tfidf_eval_itr)
--   ref_output_prefix reference output table prefix         (default: tfidf_eval_ref)

\if :{?input_tbl}
\else
\set input_tbl test_data
\endif

\if :{?doc_id_col}
\else
\set doc_id_col doc_id
\endif

\if :{?text_col}
\else
\set text_col txt
\endif

\if :{?runs}
\else
\set runs 1
\endif

\if :{?itr_output_prefix}
\else
\set itr_output_prefix tfidf_eval_itr
\endif

\if :{?ref_output_prefix}
\else
\set ref_output_prefix tfidf_eval_ref
\endif

\echo 'Running TF-IDF benchmark with:'
\echo '  input_tbl=' :input_tbl ', doc_id_col=' :doc_id_col ', text_col=' :text_col ', runs=' :runs
\timing on

DROP TABLE IF EXISTS eval_runtime_results;
CREATE TABLE eval_runtime_results (
    run_no integer NOT NULL,
    method text NOT NULL,
    output_tbl text NOT NULL,
    elapsed_ms numeric(14,3) NOT NULL
);

DO $$
BEGIN
    -- Recreate the helper function each run for script idempotence.
    EXECUTE $fn$
        CREATE OR REPLACE FUNCTION tfidf_eval_runtime(
            p_input_tbl text,
            p_doc_id_col text,
            p_text_col text,
            p_runs integer,
            p_itr_output_prefix text DEFAULT 'tfidf_eval_itr',
            p_ref_output_prefix text DEFAULT 'tfidf_eval_ref'
        )
        RETURNS void
        LANGUAGE plpgsql
        AS $body$
        DECLARE
            i integer;
            started_at timestamptz;
            elapsed_ms numeric(14,3);
            out_tbl text;
        BEGIN
            IF p_runs < 1 THEN
                RAISE EXCEPTION 'runs must be >= 1, got %', p_runs;
            END IF;

            FOR i IN 1..p_runs LOOP
                -- Iterative implementation
                out_tbl := format('%s_%s', p_itr_output_prefix, i);
                started_at := clock_timestamp();
                PERFORM hsql_create_tf_idf_tbl_itr(
                    p_input_tbl,
                    p_text_col,
                    p_doc_id_col,
                    out_tbl,
                    TRUE
                );
                EXECUTE format('DROP TABLE IF EXISTS %I', out_tbl);
                elapsed_ms := EXTRACT(EPOCH FROM (clock_timestamp() - started_at)) * 1000.0;
                INSERT INTO eval_runtime_results(run_no, method, output_tbl, elapsed_ms)
                VALUES (i, 'hsql_create_tf_idf_tbl_itr', out_tbl, elapsed_ms);

                -- Reference implementation
                out_tbl := format('%s_%s', p_ref_output_prefix, i);
                started_at := clock_timestamp();
                PERFORM hsql_create_tf_idf_tbl(
                    p_input_tbl,
                    p_doc_id_col,
                    p_text_col,
                    out_tbl,
                    TRUE
                );
                EXECUTE format('DROP TABLE IF EXISTS %I', out_tbl);
                elapsed_ms := EXTRACT(EPOCH FROM (clock_timestamp() - started_at)) * 1000.0;
                INSERT INTO eval_runtime_results(run_no, method, output_tbl, elapsed_ms)
                VALUES (i, 'hsql_create_tf_idf_tbl', out_tbl, elapsed_ms);
            END LOOP;
        END;
        $body$;
    $fn$;
END;
$$ LANGUAGE plpgsql;


-- Run evaluation using values passed from psql variables.
SELECT tfidf_eval_runtime(
    :'input_tbl',
    :'doc_id_col',
    :'text_col',
    (:'runs')::integer,
    :'itr_output_prefix',
    :'ref_output_prefix'
);

-- Per-run timings
SELECT
    run_no,
    method,
    output_tbl,
    elapsed_ms
FROM eval_runtime_results
ORDER BY run_no, method;

-- Summary statistics
SELECT
    method,
    COUNT(*) AS runs,
    ROUND(MIN(elapsed_ms), 3) AS min_ms,
    ROUND(AVG(elapsed_ms), 3) AS avg_ms,
    ROUND(MAX(elapsed_ms), 3) AS max_ms
FROM eval_runtime_results
GROUP BY method
ORDER BY avg_ms;

-- Relative comparison (avg runtime ratio)
WITH s AS (
    SELECT method, AVG(elapsed_ms) AS avg_ms
    FROM eval_runtime_results
    GROUP BY method
),
p AS (
    SELECT
        MAX(CASE WHEN method = 'hsql_create_tf_idf_tbl_itr' THEN avg_ms END) AS itr_avg_ms,
        MAX(CASE WHEN method = 'hsql_create_tf_idf_tbl' THEN avg_ms END) AS ref_avg_ms
    FROM s
)
SELECT
    ROUND(itr_avg_ms, 3) AS itr_avg_ms,
    ROUND(ref_avg_ms, 3) AS ref_avg_ms,
    ROUND(itr_avg_ms / NULLIF(ref_avg_ms, 0), 3) AS itr_over_ref_ratio
FROM p;
