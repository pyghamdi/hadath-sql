-- #########################################################
-- Tests for the hsql_entropy_c(text) and hsql_entropy_c(tsvector) aggregates
-- (C implementation, cfunc/hadathsql_c.c).
--
-- HOW TO RUN (from repository root):
--
--   psql -v ON_ERROR_STOP=1 -d <database> -f cfunc/tests/test_entropy_c.sql
--
-- PREREQUISITES
--   - HadathSQL is installed in the database (install.sql); hsql_entropy is the
--     reference that hsql_entropy_c is compared with.
--   - The hadathsql_c extension is built and installed on the server
--     (cd cfunc && make && make install). This script runs
--     CREATE EXTENSION IF NOT EXISTS hadathsql_c.
--
-- FLOW
--   1) Compare hsql_entropy_c with the expected value on small groups.
--   2) Compare hsql_entropy_c with hsql_entropy on a generated table, for text
--      and tsvector input, in a serial plan and in a parallel plan (which
--      exercises the combine, serialize, and deserialize functions).
--   The script raises an error if any check fails. It creates temporary tables
--   and one regular table, _entropy_c_test_docs, which it drops at the end (a
--   parallel plan cannot scan a temporary table).
-- #########################################################

\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS hadathsql_c;

\echo '>>> running hsql_entropy_c tests'

CREATE TEMP TABLE _entropy_c_test_results (
    test_id text PRIMARY KEY,
    want double precision NOT NULL,
    got double precision
);

INSERT INTO _entropy_c_test_results (test_id, want, got) VALUES
    (
        -- cat = 2, hat = 1, bat = 1: H = 0.5*1 + 0.25*2 + 0.25*2
        'text_one_row',
        1.5,
        (SELECT hsql_entropy_c(txt) FROM (VALUES ('cat hat cat bat')) AS v(txt))
    ),
    (
        'text_rows_are_pooled_and_null_is_ignored',
        1.5,
        (SELECT hsql_entropy_c(txt) FROM (VALUES ('cat hat'), (NULL::text), (''), ('cat bat')) AS v(txt))
    ),
    (
        -- Lowercasing, stemming, and stop-word removal: fire = 3, cat = 1
        'text_terms_are_normalized',
        0.8112781244591328,
        (SELECT hsql_entropy_c(txt) FROM (VALUES ('Fire fire fires and the cat')) AS v(txt))
    ),
    (
        'text_single_repeated_term',
        0,
        (SELECT hsql_entropy_c(txt) FROM (VALUES ('fire fire'), ('fire')) AS v(txt))
    ),
    (
        'text_only_null_and_empty_text',
        0,
        (SELECT hsql_entropy_c(txt) FROM (VALUES (NULL::text), ('')) AS v(txt))
    ),
    (
        'text_empty_group',
        0,
        (SELECT hsql_entropy_c(txt) FROM (SELECT NULL::text AS txt WHERE false) AS v)
    ),
    (
        -- Every occurrence is counted: cat = 300, dog = 100, so p = 0.75 and 0.25.
        -- (hsql_entropy(text) counts at most 256 occurrences per row.)
        'text_more_than_256_occurrences',
        0.8112781244591328,
        (SELECT hsql_entropy_c(repeat('cat ', 300) || repeat('dog ', 100)))
    ),
    (
        'tsvector_one_row',
        1.5,
        (SELECT hsql_entropy_c(to_tsvector('english', txt)) FROM (VALUES ('cat hat cat bat')) AS v(txt))
    ),
    (
        'tsvector_rows_are_pooled_and_null_is_ignored',
        1.5,
        (SELECT hsql_entropy_c(to_tsvector('english', txt))
         FROM (VALUES ('cat hat'), (NULL::text), ('cat bat')) AS v(txt))
    ),
    (
        'tsvector_empty_group',
        0,
        (SELECT hsql_entropy_c(tsv) FROM (SELECT NULL::tsvector AS tsv WHERE false) AS v)
    ),
    (
        -- The simple configuration keeps stop words and does not stem: the = 2, cat = 1.
        'tsvector_other_configuration',
        0.9182958340544896,
        (SELECT hsql_entropy_c(to_tsvector('simple', txt)) FROM (VALUES ('The the cat')) AS v(txt))
    ),
    (
        -- Without positions each term counts once per row: cat, hat, bat.
        'tsvector_without_positions',
        1.584962500721156,
        (SELECT hsql_entropy_c(strip(to_tsvector('english', txt))) FROM (VALUES ('cat hat cat bat')) AS v(txt))
    );

SELECT test_id, want, got
FROM _entropy_c_test_results
WHERE got IS NULL OR abs(got - want) > 1e-9;

DO $$
DECLARE
    failed integer;
BEGIN
    SELECT COUNT(*) INTO failed
    FROM _entropy_c_test_results
    WHERE got IS NULL OR abs(got - want) > 1e-9;
    IF failed > 0 THEN
        RAISE EXCEPTION 'hsql_entropy_c: % value test(s) failed (see the rows above)', failed;
    END IF;
END;
$$;

\echo '>>> comparing hsql_entropy_c with hsql_entropy (serial and parallel)'

-- 20,000 rows in 20 groups; the words of a row depend on its group, so the
-- groups have different entropies.
CREATE TABLE _entropy_c_test_docs AS
SELECT g % 20 AS grp,
       'word' || (g % (5 + g % 20)) || ' term' || (g % 7) || ' fire' AS txt
FROM generate_series(1, 20000) AS g;
ANALYZE _entropy_c_test_docs;

SET max_parallel_workers_per_gather = 0;
CREATE TEMP TABLE _entropy_c_test_reference AS
SELECT grp, hsql_entropy(txt) AS entropy FROM _entropy_c_test_docs GROUP BY grp;

DO $$
DECLARE
    queries text[] := ARRAY[
        'SELECT grp, hsql_entropy_c(txt) AS entropy FROM _entropy_c_test_docs GROUP BY grp',
        'SELECT grp, hsql_entropy_c(to_tsvector(''english'', txt)) AS entropy FROM _entropy_c_test_docs GROUP BY grp'];
    query text;
    parallel boolean;
    plan_line text;
    plan_text text;
    differing integer;
BEGIN
    FOREACH parallel IN ARRAY ARRAY[false, true] LOOP
        IF parallel THEN
            -- Make a parallel plan cheap enough to be chosen for this small table.
            SET LOCAL max_parallel_workers_per_gather = 2;
            SET LOCAL parallel_setup_cost = 0;
            SET LOCAL parallel_tuple_cost = 0;
            SET LOCAL min_parallel_table_scan_size = 0;
            SET LOCAL enable_sort = off;
        END IF;

        FOREACH query IN ARRAY queries LOOP
            IF parallel THEN
                plan_text := '';
                FOR plan_line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || query LOOP
                    plan_text := plan_text || plan_line || E'\n';
                END LOOP;
                IF plan_text NOT LIKE '%Partial%Aggregate%' THEN
                    RAISE EXCEPTION E'hsql_entropy_c: expected a parallel (partial) aggregate for\n%\ngot the plan\n%',
                        query, plan_text;
                END IF;
            END IF;

            EXECUTE format(
                'SELECT COUNT(*)
                 FROM _entropy_c_test_reference AS r
                 FULL JOIN (%s) AS c USING (grp)
                 WHERE r.entropy IS NULL OR c.entropy IS NULL OR abs(r.entropy - c.entropy) > 1e-9',
                query) INTO differing;
            IF differing > 0 THEN
                RAISE EXCEPTION E'hsql_entropy_c: % group(s) differ from hsql_entropy (parallel plan: %) for\n%',
                    differing, parallel, query;
            END IF;
        END LOOP;
    END LOOP;
END;
$$;

RESET max_parallel_workers_per_gather;
DROP TABLE _entropy_c_test_docs;

\echo '>>> hsql_entropy_c tests passed'
