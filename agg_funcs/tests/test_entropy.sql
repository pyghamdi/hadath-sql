-- #########################################################
-- Tests for the hsql_entropy(text) and hsql_entropy(tsvector) aggregates
-- (agg_funcs/entropy.sql).
--
-- HOW TO RUN (from repository root):
--
--   psql -v ON_ERROR_STOP=1 -d <database> -f agg_funcs/tests/test_entropy.sql
--
-- PREREQUISITES
--   - HadathSQL is installed in the database (install.sql). If hsql_entropy is
--     missing, this script loads agg_funcs/entropy.sql.
--   - English full-text configuration is available (to_tsvector('english', ...)).
--
-- FLOW
--   1) Compare hsql_entropy with the expected value on small groups.
--   2) Check that both aggregates are used in a parallel plan and that the plan
--      returns the same values as a serial plan.
--   The script raises an error if any check fails. It creates temporary tables
--   and one regular table, _entropy_test_docs, which it drops at the end (a
--   parallel plan cannot scan a temporary table).
-- #########################################################

\set ON_ERROR_STOP on

-- Load the module only when it is not installed yet. The module files create
-- their objects without dropping existing ones, so loading one twice fails.
SELECT NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'hsql_entropy') AS hsql_missing \gset
\if :hsql_missing
\ir ../entropy.sql
\endif

\echo '>>> running hsql_entropy tests'

CREATE TEMP TABLE _entropy_test_results (
    test_id text PRIMARY KEY,
    want double precision NOT NULL,
    got double precision
);

INSERT INTO _entropy_test_results (test_id, want, got) VALUES
    (
        -- cat = 2, hat = 1, bat = 1: H = 0.5*1 + 0.25*2 + 0.25*2
        'one_row',
        1.5,
        (SELECT hsql_entropy(txt) FROM (VALUES ('cat hat cat bat')) AS v(txt))
    ),
    (
        -- The rows of a group are pooled into one bag of terms.
        'rows_are_pooled',
        1.5,
        (SELECT hsql_entropy(txt) FROM (VALUES ('cat hat'), ('cat bat')) AS v(txt))
    ),
    (
        'four_equally_frequent_terms',
        2,
        (SELECT hsql_entropy(txt) FROM (VALUES ('red blue'), ('green yellow')) AS v(txt))
    ),
    (
        'single_repeated_term',
        0,
        (SELECT hsql_entropy(txt) FROM (VALUES ('fire fire'), ('fire')) AS v(txt))
    ),
    (
        -- Fire, fire, and fires are the same term after lowercasing and stemming.
        'case_and_stemming_are_normalized',
        0,
        (SELECT hsql_entropy(txt) FROM (VALUES ('Fire fire fires')) AS v(txt))
    ),
    (
        -- "the" and "a" are stop words: only cat and dog are counted.
        'stop_words_are_ignored',
        1,
        (SELECT hsql_entropy(txt) FROM (VALUES ('the cat and a dog')) AS v(txt))
    ),
    (
        'null_and_empty_text_are_ignored',
        1,
        (SELECT hsql_entropy(txt) FROM (VALUES ('cat'), (NULL::text), (''), ('dog')) AS v(txt))
    ),
    (
        'only_null_and_empty_text',
        0,
        (SELECT hsql_entropy(txt) FROM (VALUES (NULL::text), ('')) AS v(txt))
    ),
    (
        'empty_group',
        0,
        (SELECT hsql_entropy(txt) FROM (SELECT NULL::text AS txt WHERE false) AS v)
    ),
    (
        -- cat = 3, dog = 1: H = 0.75*log2(4/3) + 0.25*log2(4)
        'unequal_frequencies',
        0.8112781244591328,
        (SELECT hsql_entropy(txt) FROM (VALUES ('cat cat dog'), ('cat')) AS v(txt))
    ),
    (
        -- Merging two partial states gives the state of the whole group.
        'combine_merges_partial_states',
        1.5,
        (SELECT hsql_entropy_final(array_cat(ARRAY['cat hat'], ARRAY['cat bat'])))
    ),
    (
        'tsvector_one_row',
        1.5,
        (SELECT hsql_entropy(to_tsvector('english', txt)) FROM (VALUES ('cat hat cat bat')) AS v(txt))
    ),
    (
        'tsvector_rows_are_pooled_and_null_is_ignored',
        1.5,
        (SELECT hsql_entropy(to_tsvector('english', txt))
         FROM (VALUES ('cat hat'), (NULL::text), ('cat bat')) AS v(txt))
    ),
    (
        'tsvector_empty_group',
        0,
        (SELECT hsql_entropy(tsv) FROM (SELECT NULL::tsvector AS tsv WHERE false) AS v)
    ),
    (
        -- The simple configuration keeps stop words and does not stem:
        -- the = 2, cat = 1.
        'tsvector_other_configuration',
        0.9182958340544896,
        (SELECT hsql_entropy(to_tsvector('simple', txt)) FROM (VALUES ('The the cat')) AS v(txt))
    ),
    (
        -- Without positions each term counts once per row: cat, hat, bat.
        'tsvector_without_positions',
        1.584962500721156,
        (SELECT hsql_entropy(strip(to_tsvector('english', txt))) FROM (VALUES ('cat hat cat bat')) AS v(txt))
    ),
    (
        'tsvector_combine_merges_partial_states',
        1.5,
        (SELECT hsql_entropy_final(array_cat(ARRAY[to_tsvector('english', 'cat hat')],
                                             ARRAY[to_tsvector('english', 'cat bat')])))
    );

SELECT test_id, want, got
FROM _entropy_test_results
WHERE got IS NULL OR abs(got - want) > 1e-9;

DO $$
DECLARE
    failed integer;
BEGIN
    SELECT COUNT(*) INTO failed
    FROM _entropy_test_results
    WHERE got IS NULL OR abs(got - want) > 1e-9;
    IF failed > 0 THEN
        RAISE EXCEPTION 'hsql_entropy: % value test(s) failed (see the rows above)', failed;
    END IF;
END;
$$;

\echo '>>> running hsql_entropy parallel test'

-- 20,000 rows in 20 groups; the words of a row depend on its group, so the
-- groups have different entropies.
CREATE TEMP TABLE _entropy_test_serial (grp integer PRIMARY KEY, entropy double precision);
CREATE TEMP TABLE _entropy_test_parallel (grp integer PRIMARY KEY, entropy double precision);
CREATE TEMP TABLE _entropy_test_parallel_tsv (grp integer PRIMARY KEY, entropy double precision);
CREATE TABLE _entropy_test_docs AS
SELECT g % 20 AS grp,
       'word' || (g % (5 + g % 20)) || ' term' || (g % 7) || ' fire' AS txt
FROM generate_series(1, 20000) AS g;
ANALYZE _entropy_test_docs;

SET max_parallel_workers_per_gather = 0;
INSERT INTO _entropy_test_serial
SELECT grp, hsql_entropy(txt) FROM _entropy_test_docs GROUP BY grp;

-- Make a parallel plan cheap enough to be chosen for this small table.
SET max_parallel_workers_per_gather = 2;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET enable_sort = off;

DO $$
DECLARE
    queries text[] := ARRAY[
        'SELECT grp, hsql_entropy(txt) FROM _entropy_test_docs GROUP BY grp',
        'SELECT grp, hsql_entropy(to_tsvector(''english'', txt)) FROM _entropy_test_docs GROUP BY grp'];
    targets text[] := ARRAY['_entropy_test_parallel', '_entropy_test_parallel_tsv'];
    plan_line text;
    plan_text text;
    differing integer;
BEGIN
    FOR i IN 1..2 LOOP
        plan_text := '';
        FOR plan_line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || queries[i] LOOP
            plan_text := plan_text || plan_line || E'\n';
        END LOOP;
        IF plan_text NOT LIKE '%Partial%Aggregate%' THEN
            RAISE EXCEPTION E'hsql_entropy: expected a parallel (partial) aggregate for\n%\ngot the plan\n%',
                queries[i], plan_text;
        END IF;

        EXECUTE format('INSERT INTO %I %s', targets[i], queries[i]);

        EXECUTE format(
            'SELECT COUNT(*)
             FROM _entropy_test_serial AS s
             FULL JOIN %I AS p USING (grp)
             WHERE s.entropy IS NULL OR p.entropy IS NULL OR abs(s.entropy - p.entropy) > 1e-9',
            targets[i]) INTO differing;
        IF differing > 0 THEN
            RAISE EXCEPTION 'hsql_entropy: % group(s) differ between the serial plan and the parallel plan of\n%',
                differing, queries[i];
        END IF;
    END LOOP;
END;
$$;

RESET max_parallel_workers_per_gather;
RESET parallel_setup_cost;
RESET parallel_tuple_cost;
RESET min_parallel_table_scan_size;
RESET enable_sort;
DROP TABLE _entropy_test_docs;

\echo '>>> hsql_entropy tests passed'
