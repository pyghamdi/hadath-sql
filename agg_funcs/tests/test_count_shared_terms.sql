-- #########################################################
-- Tests for the hsql_count_shared_terms(text, integer) and
-- hsql_count_shared_terms(tsvector, integer) aggregates
-- (agg_funcs/count_shared_terms.sql).
--
-- HOW TO RUN (from repository root):
--
--   psql -v ON_ERROR_STOP=1 -d <database> -f agg_funcs/tests/test_count_shared_terms.sql
--
-- PREREQUISITES
--   - HadathSQL is installed in the database (install.sql). If
--     hsql_count_shared_terms is missing, this script loads
--     agg_funcs/count_shared_terms.sql.
--   - English full-text configuration is available (to_tsvector('english', ...)).
--
-- FLOW
--   1) Compare the aggregates with the expected value on small groups.
--   2) Compute the aggregates on a generated table in a serial plan and in a
--      parallel plan, and check that the parallel plan is used and returns
--      the same values as a serial plan.
--   The script raises an error if any check fails. It creates temporary tables
--   and one regular table, _shared_terms_test_docs, which it drops at the end (a
--   parallel plan cannot scan a temporary table).
-- #########################################################

\set ON_ERROR_STOP on

-- Load the module only when it is not installed yet. The module files create
-- their objects without dropping existing ones, so loading one twice fails.
SELECT NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'hsql_count_shared_terms') AS hsql_missing \gset
\if :hsql_missing
\ir ../count_shared_terms.sql
\endif

\echo '>>> running hsql_count_shared_terms tests'

CREATE TEMP TABLE _shared_terms_test_results (
    test_id text PRIMARY KEY,
    want integer NOT NULL,
    got integer
);

INSERT INTO _shared_terms_test_results (test_id, want, got) VALUES
    (
        'three_terms_in_three_rows_min3',
        3,
        (SELECT hsql_count_shared_terms(txt, 3)
         FROM (VALUES ('apple banana cherry'), ('apple banana cherry'), ('apple banana cherry')) AS v(txt))
    ),
    (
        'two_rows_below_min3',
        0,
        (SELECT hsql_count_shared_terms(txt, 3)
         FROM (VALUES ('apple banana cherry'), ('apple banana cherry')) AS v(txt))
    ),
    (
        'three_shared_terms_min2_mixed_rows',
        3,
        (SELECT hsql_count_shared_terms(txt, 2)
         FROM (VALUES ('apple banana cherry'), ('apple banana cherry'), ('dog elephant')) AS v(txt))
    ),
    (
        -- A term repeated inside one row counts once for that row.
        'repeated_term_counts_once_per_row',
        1,
        (SELECT hsql_count_shared_terms(txt, 2) FROM (VALUES ('apple apple apple'), ('apple apple')) AS v(txt))
    ),
    (
        'repeated_term_in_a_single_row_is_not_shared',
        0,
        (SELECT hsql_count_shared_terms(txt, 2) FROM (VALUES ('apple apple apple'), ('banana')) AS v(txt))
    ),
    (
        'one_shared_term_among_three_rows',
        1,
        (SELECT hsql_count_shared_terms(txt, 2)
         FROM (VALUES ('apple apple apple'), ('apple banana'), ('apple cherry')) AS v(txt))
    ),
    (
        -- Fire, fire, and fires are the same term; "the" is a stop word.
        'terms_are_normalized',
        1,
        (SELECT hsql_count_shared_terms(txt, 3) FROM (VALUES ('The Fire'), ('the fires'), ('fire the')) AS v(txt))
    ),
    (
        'minimum_one_counts_all_distinct_terms',
        3,
        (SELECT hsql_count_shared_terms(txt, 1) FROM (VALUES ('apple banana'), ('apple cherry')) AS v(txt))
    ),
    (
        'null_and_empty_text_are_ignored',
        1,
        (SELECT hsql_count_shared_terms(txt, 2) FROM (VALUES ('apple'), (NULL::text), (''), ('apple')) AS v(txt))
    ),
    (
        'only_null_and_empty_text',
        0,
        (SELECT hsql_count_shared_terms(txt, 1) FROM (VALUES (NULL::text), ('')) AS v(txt))
    ),
    (
        'empty_group',
        0,
        (SELECT hsql_count_shared_terms(txt, 3) FROM (SELECT NULL::text AS txt WHERE false) AS v)
    ),
    (
        'tsvector_three_shared_terms',
        3,
        (SELECT hsql_count_shared_terms(to_tsvector('english', txt), 2)
         FROM (VALUES ('apple banana cherry'), ('apple banana cherry'), ('dog elephant')) AS v(txt))
    ),
    (
        'tsvector_null_is_ignored',
        1,
        (SELECT hsql_count_shared_terms(to_tsvector('english', txt), 2)
         FROM (VALUES ('apple apple'), (NULL::text), ('apple banana')) AS v(txt))
    ),
    (
        'tsvector_empty_group',
        0,
        (SELECT hsql_count_shared_terms(tsv, 2) FROM (SELECT NULL::tsvector AS tsv WHERE false) AS v)
    ),
    (
        -- The simple configuration keeps stop words: "the" is shared by both rows.
        'tsvector_other_configuration',
        1,
        (SELECT hsql_count_shared_terms(to_tsvector('simple', txt), 2) FROM (VALUES ('the cat'), ('the dog')) AS v(txt))
    )
    ,
    (
        -- Merging two partial states gives the state of the whole group.
        'combine_merges_partial_states',
        3,
        (SELECT hsql_count_shared_terms_final(hsql_count_shared_terms_combine(
            ARRAY['2', 'apple banana cherry', 'apple banana cherry'],
            ARRAY['2', 'dog elephant', 'cherry'])))
    ),
    (
        'combine_with_an_empty_state',
        1,
        (SELECT hsql_count_shared_terms_final(hsql_count_shared_terms_combine(
            '{}'::text[], ARRAY['2', 'apple', 'apple'])))
    );

SELECT test_id, want, got
FROM _shared_terms_test_results
WHERE got IS DISTINCT FROM want;

DO $$
DECLARE
    failed integer;
BEGIN
    SELECT COUNT(*) INTO failed
    FROM _shared_terms_test_results
    WHERE got IS DISTINCT FROM want;
    IF failed > 0 THEN
        RAISE EXCEPTION 'hsql_count_shared_terms: % value test(s) failed (see the rows above)', failed;
    END IF;
END;
$$;

\echo '>>> running hsql_count_shared_terms serial and parallel test'

-- 20,000 rows in 20 groups; the words of a row depend on its group, so the
-- groups have different numbers of shared terms.
CREATE TABLE _shared_terms_test_docs AS
SELECT g % 20 AS grp,
       'word' || (g % (5 + g % 20)) || ' term' || (g % 997) || ' fire' AS txt
FROM generate_series(1, 20000) AS g;
ANALYZE _shared_terms_test_docs;

SET max_parallel_workers_per_gather = 0;
CREATE TEMP TABLE _shared_terms_test_reference AS
SELECT grp, hsql_count_shared_terms(txt, 3) AS shared FROM _shared_terms_test_docs GROUP BY grp;

DO $$
DECLARE
    queries text[] := ARRAY[
        'SELECT grp, hsql_count_shared_terms(txt, 3) AS shared FROM _shared_terms_test_docs GROUP BY grp',
        'SELECT grp, hsql_count_shared_terms(to_tsvector(''english'', txt), 3) AS shared FROM _shared_terms_test_docs GROUP BY grp'];
    query text;
    parallel boolean;
    plan_line text;
    plan_text text;
    differing integer;
    distinct_values integer;
BEGIN
    -- The reference must not be trivial: the groups have different results.
    SELECT COUNT(DISTINCT shared) INTO distinct_values FROM _shared_terms_test_reference;
    IF distinct_values < 2 THEN
        RAISE EXCEPTION 'hsql_count_shared_terms: the generated groups all have the same result';
    END IF;

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
                    RAISE EXCEPTION E'hsql_count_shared_terms: expected a parallel (partial) aggregate for\n%\ngot the plan\n%',
                        query, plan_text;
                END IF;
            END IF;

            EXECUTE format(
                'SELECT COUNT(*)
                 FROM _shared_terms_test_reference AS r
                 FULL JOIN (%s) AS c USING (grp)
                 WHERE r.shared IS DISTINCT FROM c.shared',
                query) INTO differing;
            IF differing > 0 THEN
                RAISE EXCEPTION E'hsql_count_shared_terms: % group(s) differ from the reference (parallel plan: %) for\n%',
                    differing, parallel, query;
            END IF;
        END LOOP;
    END LOOP;
END;
$$;

RESET max_parallel_workers_per_gather;
DROP TABLE _shared_terms_test_docs;

\echo '>>> hsql_count_shared_terms tests passed'
