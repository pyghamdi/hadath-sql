-- #########################################################
-- time_partition UDF runtime evaluation
-- #########################################################
--
-- Builds a 1M-row table with varied timestamps, then benchmarks
-- time_partition() on 100K, 200K, ... 1M rows.
--
-- Usage (from repository root):
--   PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5432 -U postgres \
--     -d hadathdb -f time_partition/evaluation/eval.sql
--
-- Optional psql variables:
--   source_tbl        benchmark input table name          (default: time_partition_eval_data)
--   interval_length   partition interval                  (default: 15 minutes)
--   shift_interval    partition shift                     (default: 0 minutes)
--   max_rows          total rows to generate              (default: 1000000)
--   step_rows         row-count increment per benchmark   (default: 100000)
--   recreate_data     drop/recreate input table (t/f)     (default: true)

\set ON_ERROR_STOP on

\if :{?source_tbl}
\else
\set source_tbl time_partition_eval_data
\endif

\if :{?interval_length}
\else
\set interval_length '15 minutes'
\endif

\if :{?shift_interval}
\else
\set shift_interval '0 minutes'
\endif

\if :{?max_rows}
\else
\set max_rows 1000000
\endif

\if :{?step_rows}
\else
\set step_rows 100000
\endif

\if :{?recreate_data}
\else
\set recreate_data true
\endif

\echo '>>> time_partition benchmark settings'
\echo '    source_tbl=' :source_tbl
\echo '    interval_length=' :interval_length
\echo '    shift_interval=' :shift_interval
\echo '    max_rows=' :max_rows ', step_rows=' :step_rows
\echo '    recreate_data=' :recreate_data

-- Ensure the UDF exists (idempotent when setup_udfs.sql was already run).
\ir ../time_partitioning.sql

\if :recreate_data
\echo '>>> creating benchmark table:' :source_tbl '(' :max_rows ' rows)'

DROP TABLE IF EXISTS :"source_tbl";

CREATE TABLE :"source_tbl" (
    id integer PRIMARY KEY,
    ts timestamp NOT NULL
);

INSERT INTO :"source_tbl" (id, ts)
SELECT
    g AS id,
    -- Spread timestamps across ~4 years, all seconds within a day, and a
    -- small day-offset pattern so partition boundaries (midnight, shifts)
    -- are exercised rather than using a single repeated instant.
    TIMESTAMP '2020-01-01 00:00:00'
        + ((g - 1) % 1461) * INTERVAL '1 day'
        + ((g - 1) % 86400) * INTERVAL '1 second'
        + ((g - 1) % 17) * INTERVAL '1 millisecond'
FROM generate_series(1, :max_rows) AS g;

ANALYZE :"source_tbl";

SELECT COUNT(*) AS row_count, MIN(ts) AS min_ts, MAX(ts) AS max_ts
FROM :"source_tbl";
\else
\echo '>>> reusing existing benchmark table:' :source_tbl
SELECT COUNT(*) AS row_count, MIN(ts) AS min_ts, MAX(ts) AS max_ts
FROM :"source_tbl";
\endif

DROP TABLE IF EXISTS time_partition_eval_results;

CREATE TABLE time_partition_eval_results (
    row_limit integer NOT NULL,
    interval_length interval NOT NULL,
    shift_interval interval NOT NULL,
    elapsed_ms numeric(14, 3) NOT NULL,
    checksum bigint NOT NULL
);

DO $$
BEGIN
    EXECUTE $fn$
        CREATE OR REPLACE FUNCTION time_partition_eval_runtime(
            p_source_tbl text,
            p_interval_length interval,
            p_shift_interval interval,
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
            v_checksum bigint;
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
                v_started_at := clock_timestamp();

                EXECUTE format(
                    $q$
                    SELECT COALESCE(
                        SUM(
                            EXTRACT(
                                EPOCH FROM (
                                    time_partition(ts, $1, $2)
                                ).start_timestamp
                            )
                        ),
                        0
                    )::bigint
                    FROM %I
                    WHERE id <= $3
                    $q$,
                    p_source_tbl
                )
                INTO v_checksum
                USING p_interval_length, p_shift_interval, v_row_limit;

                v_elapsed_ms :=
                    EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at)) * 1000.0;

                INSERT INTO time_partition_eval_results (
                    row_limit,
                    interval_length,
                    shift_interval,
                    elapsed_ms,
                    checksum
                )
                VALUES (
                    v_row_limit,
                    p_interval_length,
                    p_shift_interval,
                    v_elapsed_ms,
                    v_checksum
                );

                RAISE NOTICE 'time_partition on % rows: % ms (checksum=%)',
                    v_row_limit,
                    ROUND(v_elapsed_ms, 3),
                    v_checksum;
            END LOOP;
        END;
        $body$;
    $fn$;
END;
$$;

SELECT time_partition_eval_runtime(
    :'source_tbl',
    :'interval_length'::interval,
    :'shift_interval'::interval,
    :'max_rows'::integer,
    :'step_rows'::integer
);

\echo '>>> per-run timings'
SELECT
    row_limit,
    interval_length,
    shift_interval,
    ROUND(elapsed_ms, 3) AS elapsed_ms,
    ROUND(elapsed_ms / row_limit, 6) AS ms_per_row,
    checksum
FROM time_partition_eval_results
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
FROM time_partition_eval_results;
