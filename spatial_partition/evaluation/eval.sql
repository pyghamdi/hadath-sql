-- #########################################################
-- hsql_spatial_partition UDF runtime evaluation
-- #########################################################
--
-- Builds a 1M-row table with Web Mercator (EPSG:3857) coordinates,
-- then benchmarks hsql_spatial_partition() on 100K, 200K, ... 1M rows.
--
-- Usage (from repository root):
--   PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5432 -U postgres \
--     -d hadathdb -f spatial_partition/evaluation/eval.sql
--
-- Optional psql variables:
--   source_tbl        benchmark input table name          (default: spatial_partition_eval_data)
--   cell_length       grid cell size in meters            (default: 50000)
--   max_rows          total rows to generate              (default: 1000000)
--   step_rows         row-count increment per benchmark   (default: 100000)
--   recreate_data     drop/recreate input table (t/f)     (default: true)

\set ON_ERROR_STOP on

\if :{?source_tbl}
\else
\set source_tbl spatial_partition_eval_data
\endif

\if :{?cell_length}
\else
\set cell_length 50000
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

\echo '>>> spatial_partition benchmark settings'
\echo '    source_tbl=' :source_tbl
\echo '    cell_length=' :cell_length ' meters'
\echo '    max_rows=' :max_rows ', step_rows=' :step_rows
\echo '    recreate_data=' :recreate_data

-- Ensure the UDF exists (idempotent when install.sql was already run).
\ir ../space_partition.sql

\if :recreate_data
\echo '>>> creating benchmark table:' :source_tbl '(' :max_rows ' rows)'

DROP TABLE IF EXISTS :"source_tbl";

CREATE TABLE :"source_tbl" (
    id integer PRIMARY KEY,
    x double precision NOT NULL,
    y double precision NOT NULL
);

INSERT INTO :"source_tbl" (id, x, y)
SELECT
    g AS id,
    -- Web Mercator bounds (EPSG:3857): ~[-20037508.34, +20037508.34]
    -- Spread points across the full extent with varied offsets so grid
    -- cell boundaries are exercised rather than collapsing to one cell.
    -20037508.34
        + ((g - 1) % 40075017) * (40075016.68 / 40075017.0)
        + ((g - 1) % 137) * 0.01 AS x,
    -20037508.34
        + (((g - 1) * 17) % 40075017) * (40075016.68 / 40075017.0)
        + ((g - 1) % 89) * 0.01 AS y
FROM generate_series(1, :max_rows) AS g;

ANALYZE :"source_tbl";

SELECT
    COUNT(*) AS row_count,
    ROUND(MIN(x)::numeric, 3) AS min_x,
    ROUND(MAX(x)::numeric, 3) AS max_x,
    ROUND(MIN(y)::numeric, 3) AS min_y,
    ROUND(MAX(y)::numeric, 3) AS max_y
FROM :"source_tbl";
\else
\echo '>>> reusing existing benchmark table:' :source_tbl
SELECT
    COUNT(*) AS row_count,
    ROUND(MIN(x)::numeric, 3) AS min_x,
    ROUND(MAX(x)::numeric, 3) AS max_x,
    ROUND(MIN(y)::numeric, 3) AS min_y,
    ROUND(MAX(y)::numeric, 3) AS max_y
FROM :"source_tbl";
\endif

DROP TABLE IF EXISTS spatial_partition_eval_results;

CREATE TABLE spatial_partition_eval_results (
    row_limit integer NOT NULL,
    cell_length numeric NOT NULL,
    elapsed_ms numeric(14, 3) NOT NULL,
    checksum bigint NOT NULL
);

DO $$
BEGIN
    EXECUTE $fn$
        CREATE OR REPLACE FUNCTION hsql_spatial_partition_eval_runtime(
            p_source_tbl text,
            p_cell_length numeric,
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
                        SUM((p).x::bigint * 1000000 + (p).y::bigint),
                        0
                    )::bigint
                    FROM (
                        SELECT hsql_spatial_partition(x, y, $1) AS p
                        FROM %I
                        WHERE id <= $2
                    ) partitioned
                    $q$,
                    p_source_tbl
                )
                INTO v_checksum
                USING p_cell_length, v_row_limit;

                v_elapsed_ms :=
                    EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at)) * 1000.0;

                INSERT INTO spatial_partition_eval_results (
                    row_limit,
                    cell_length,
                    elapsed_ms,
                    checksum
                )
                VALUES (
                    v_row_limit,
                    p_cell_length,
                    v_elapsed_ms,
                    v_checksum
                );

                RAISE NOTICE 'hsql_spatial_partition on % rows: % ms (checksum=%)',
                    v_row_limit,
                    ROUND(v_elapsed_ms, 3),
                    v_checksum;
            END LOOP;
        END;
        $body$;
    $fn$;
END;
$$;

SELECT hsql_spatial_partition_eval_runtime(
    :'source_tbl',
    :'cell_length'::numeric,
    :'max_rows'::integer,
    :'step_rows'::integer
);

\echo '>>> per-run timings'
SELECT
    row_limit,
    cell_length,
    ROUND(elapsed_ms, 3) AS elapsed_ms,
    ROUND(elapsed_ms / row_limit, 6) AS ms_per_row,
    checksum
FROM spatial_partition_eval_results
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
FROM spatial_partition_eval_results;
