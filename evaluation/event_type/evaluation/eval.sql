-- #########################################################
-- Event-type UDFs runtime evaluation
-- #########################################################
--
-- Builds a synthetic table of short documents, trains a prototype classifier
-- on part of it, and measures the time to select the documents that report an
-- earthquake with:
--   keyword_only         hsql_overlap(txt, kw) > 0
--   classifier_only      hsql_event_type(txt, type)
--   two_udfs             hsql_overlap(txt, kw) > 0 AND hsql_event_type(txt, type)
--   one_udf_inlined      hsql_event_type(txt, type, kw)
--   one_udf_plpgsql      one PL/pgSQL function that does both stages
--   one_udf_sql          one SQL function that does both stages and is not inlined
--   two_udfs_tsvector    two_udfs on a stored tsvector column
--   two_udfs_gin_index   hsql_has_keyword(txt, kw) AND hsql_event_type(txt, type),
--                        with a GIN index on to_tsvector('english', txt)
--
-- one_udf_plpgsql and one_udf_sql are defined in this script only. They extract
-- the terms of a document once and are called once per document; they receive
-- the keywords as a tsquery so that the keywords are processed once per query.
--
-- The classifier is trained only to measure execution time; its accuracy on
-- the synthetic documents has no meaning.
--
-- Usage (from repository root):
--   python3 evaluation/event_type/evaluation/run_eval.py
-- runs this script for several keyword fractions in a database of its own and
-- saves the results. To run it once in an existing database:
--   psql -v ON_ERROR_STOP=1 -d <database> -f evaluation/event_type/evaluation/eval.sql
--
-- Optional psql variables:
--   n_rows        number of documents                         (default: 50000)
--   kw_fraction   fraction of documents with a keyword        (default: 0.1)
--   train_rows    number of documents used for training       (default: 20000)
--   runs          timed runs per query, after one warm-up run (default: 15)
--
-- The script creates the tables event_type_eval_docs, event_type_eval_train,
-- event_type_eval_queries, and event_type_eval_results, and replaces the
-- classifier of the event type 'earthquake' in hsql_event_type_model. The data
-- is generated from a fixed random seed.

\set ON_ERROR_STOP on

\if :{?n_rows}
\else
\set n_rows 50000
\endif

\if :{?kw_fraction}
\else
\set kw_fraction 0.1
\endif

\if :{?train_rows}
\else
\set train_rows 20000
\endif

\if :{?runs}
\else
\set runs 15
\endif

\echo '>>> event_type benchmark settings'
\echo '    n_rows=' :n_rows ', kw_fraction=' :kw_fraction
\echo '    train_rows=' :train_rows ', runs=' :runs

-- Load the module only when it is not installed yet. The module files create
-- their objects without dropping existing ones, so loading one twice fails.
SELECT NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'hsql_event_type') AS hsql_missing \gset
\if :hsql_missing
\ir ../../../event_type/event_type.sql
\endif

-- Measure the cost per document in one process, without JIT compilation,
-- whose compile time would be added to some of the queries and not to others.
SET max_parallel_workers_per_gather = 0;
SET jit = off;

-- Passes the number of runs to the DO block that times the queries.
SELECT set_config('hsql_eval.runs', :'runs', false);

-- ---------------------------------------------------------
-- Data
-- ---------------------------------------------------------
\echo '>>> creating event_type_eval_docs (' :n_rows ' rows)'

DROP TABLE IF EXISTS event_type_eval_docs;
DROP TABLE IF EXISTS event_type_eval_train;

SELECT setseed(0.42);

-- A vocabulary of 5000 words of 8 letters.
CREATE TEMP TABLE _event_type_eval_vocab AS
SELECT g AS id,
       translate(substr(md5(g::text), 1, 8), '0123456789', 'ghijklmnop') AS word
FROM generate_series(1, 5000) AS g;

-- Each document has 12 random words. A fraction kw_fraction of the documents
-- also has a keyword: half of these report an earthquake, and the other half
-- use the keyword in another sense.
CREATE TABLE event_type_eval_docs AS
WITH words AS (
    SELECT (r.i - 1) / 12 + 1 AS id, string_agg(v.word, ' ') AS txt
    FROM (
        SELECT i, 1 + floor(random() * 5000)::integer AS k
        FROM generate_series(1, :n_rows * 12) AS i
    ) AS r
    JOIN _event_type_eval_vocab AS v ON v.id = r.k
    GROUP BY 1
),
draws AS (
    SELECT id, txt, random() < :kw_fraction AS has_keyword, floor(random() * 4)::integer AS variant
    FROM words
)
SELECT id,
       txt || CASE
           WHEN NOT has_keyword THEN ''
           WHEN variant = 0 THEN ' earthquake felt a strong tremor right now'
           WHEN variant = 1 THEN ' everything is shaking right now tremor'
           WHEN variant = 2 THEN ' attending an earthquake conference next week'
           ELSE ' someone is shaking hands with my boss'
       END AS txt,
       has_keyword AND variant < 2 AS is_earthquake
FROM draws;

ALTER TABLE event_type_eval_docs ADD PRIMARY KEY (id);
ALTER TABLE event_type_eval_docs ADD COLUMN tsv tsvector;
UPDATE event_type_eval_docs SET tsv = to_tsvector('english', txt);
VACUUM (FULL, ANALYZE) event_type_eval_docs;

CREATE TABLE event_type_eval_train AS
SELECT txt, is_earthquake FROM event_type_eval_docs WHERE id <= :train_rows;

SELECT COUNT(*) AS row_count,
       COUNT(*) FILTER (WHERE hsql_overlap(txt, 'earthquake, shaking') > 0) AS with_keyword,
       COUNT(*) FILTER (WHERE is_earthquake) AS report_earthquake
FROM event_type_eval_docs;

\echo '>>> training the classifier'
SELECT hsql_train_event_type('earthquake', 'event_type_eval_train', 'txt', 'is_earthquake') AS model_terms;
ANALYZE hsql_event_type_model;

-- ---------------------------------------------------------
-- Single-call functions that are not inlined
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION hsql_event_type_eval_plpgsql(txt text, type text, keywords tsquery)
RETURNS boolean
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
AS $$
DECLARE
    tsv tsvector := to_tsvector('english', txt);
    score double precision;
BEGIN
    IF NOT tsv @@ keywords THEN
        RETURN false;
    END IF;
    SELECT sum(m.weight) INTO score
    FROM unnest(array_append(tsvector_to_array(tsv), '')) AS t(term)
    JOIN hsql_event_type_model AS m ON m.term = t.term AND m.event_type = type;
    RETURN score > 0;
END;
$$;

CREATE OR REPLACE FUNCTION hsql_event_type_eval_sql(txt text, type text, keywords tsquery)
RETURNS boolean
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN d.tsv @@ keywords THEN (
            SELECT sum(m.weight) > 0
            FROM unnest(array_append(tsvector_to_array(d.tsv), '')) AS t(term)
            JOIN hsql_event_type_model AS m ON m.term = t.term AND m.event_type = type)
        ELSE false
    END
    FROM (SELECT to_tsvector('english', txt) AS tsv OFFSET 0) AS d;
$$;

-- ---------------------------------------------------------
-- Timing
-- ---------------------------------------------------------
-- The index is created before the timed runs. Only two_udfs_gin_index can use
-- it: the other queries apply their predicates to every document.
CREATE INDEX event_type_eval_docs_txt_idx
    ON event_type_eval_docs USING gin (to_tsvector('english', txt));
ANALYZE event_type_eval_docs;

DROP TABLE IF EXISTS event_type_eval_queries;

CREATE TABLE event_type_eval_queries (position integer, query text, predicate text);

INSERT INTO event_type_eval_queries VALUES
    (1, 'keyword_only',
        $$hsql_overlap(txt, 'earthquake, shaking') > 0$$),
    (2, 'classifier_only',
        $$hsql_event_type(txt, 'earthquake')$$),
    (3, 'two_udfs',
        $$hsql_overlap(txt, 'earthquake, shaking') > 0 AND hsql_event_type(txt, 'earthquake')$$),
    (4, 'one_udf_inlined',
        $$hsql_event_type(txt, 'earthquake', 'earthquake, shaking')$$),
    (5, 'one_udf_plpgsql',
        $$hsql_event_type_eval_plpgsql(txt, 'earthquake', hsql_keywords_tsquery('earthquake, shaking'))$$),
    (6, 'one_udf_sql',
        $$hsql_event_type_eval_sql(txt, 'earthquake', hsql_keywords_tsquery('earthquake, shaking'))$$),
    (7, 'two_udfs_tsvector',
        $$hsql_overlap(tsv, 'earthquake, shaking') > 0 AND hsql_event_type(tsv, 'earthquake')$$),
    (8, 'two_udfs_gin_index',
        $$hsql_has_keyword(txt, 'earthquake, shaking') AND hsql_event_type(txt, 'earthquake')$$);

DROP TABLE IF EXISTS event_type_eval_results;

CREATE TABLE event_type_eval_results (
    query text NOT NULL,
    run integer NOT NULL,
    selected_rows bigint NOT NULL,
    elapsed_ms numeric(12, 1) NOT NULL,
    PRIMARY KEY (query, run)
);

-- Counts the documents that satisfy each predicate. The queries are run in
-- rounds, each round running every query once, so that a change of the speed
-- of the machine during the benchmark affects all the queries. The table is
-- kept small so that a round is short and the queries of a round run at the
-- same speed. Run 0 is a warm-up round and is not reported.
DO $$
DECLARE
    v_runs integer := current_setting('hsql_eval.runs')::integer;
    v_query record;
    v_count bigint;
    v_started_at timestamptz;
BEGIN
    FOR v_run IN 0..v_runs LOOP
        FOR v_query IN SELECT * FROM event_type_eval_queries ORDER BY position LOOP
            v_started_at := clock_timestamp();
            EXECUTE 'SELECT COUNT(*) FROM event_type_eval_docs WHERE ' || v_query.predicate
                INTO v_count;
            INSERT INTO event_type_eval_results VALUES (
                v_query.query, v_run, v_count,
                EXTRACT(EPOCH FROM clock_timestamp() - v_started_at) * 1000);
        END LOOP;
    END LOOP;
END;
$$;

\echo '>>> plan of two_udfs_gin_index'
EXPLAIN (COSTS OFF)
SELECT COUNT(*) FROM event_type_eval_docs
WHERE hsql_has_keyword(txt, 'earthquake, shaking') AND hsql_event_type(txt, 'earthquake');

-- The queries that apply both stages have to select the same documents.
DO $$
BEGIN
    IF (SELECT COUNT(DISTINCT selected_rows)
        FROM event_type_eval_results
        WHERE query NOT IN ('keyword_only', 'classifier_only')) <> 1 THEN
        RAISE EXCEPTION 'the queries that apply both stages selected different numbers of rows';
    END IF;
END;
$$;

-- ratio_to_two_udfs is the median, over the rounds, of the time of the query
-- divided by the time of two_udfs in the same round. It compares runs that
-- are close in time, so it is not affected by a change of the speed of the
-- machine between rounds, unlike a ratio of two minimum or median times.
\echo '>>> results (times in ms)'
SELECT r.query,
       MIN(r.selected_rows) AS selected_rows,
       MIN(r.elapsed_ms) AS min_ms,
       (percentile_cont(0.5) WITHIN GROUP (ORDER BY r.elapsed_ms))::numeric(12, 1) AS median_ms,
       (percentile_cont(0.5) WITHIN GROUP (ORDER BY r.elapsed_ms / t.elapsed_ms))::numeric(8, 2)
           AS ratio_to_two_udfs
FROM event_type_eval_results AS r
JOIN event_type_eval_results AS t ON t.run = r.run AND t.query = 'two_udfs'
WHERE r.run > 0
GROUP BY r.query
ORDER BY ratio_to_two_udfs;
