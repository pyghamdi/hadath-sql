-- #########################################################
-- Tests for hsql_count_shared_terms(txt, minimum) aggregate (agg_funcs/count_shared_terms.sql).
--
-- HOW TO RUN (from repository root):
--
--   PGPASSWORD=postgres psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5432 -U postgres \
--     -d postgres -f agg_funcs/tests/test_count_shared_terms.sql
--
-- Override connection defaults with psql -v:
--   db_host, db_port, db_name, db_user, db_password, db_admin_name
--
-- PREREQUISITES
--   - Role can connect to db_name (created if missing, like tf_idf parity tests).
--   - English full-text config available (to_tsvector('english', ...)).
--
-- FLOW
--   1) Ensure db_name exists
--   2) Load tf_idf/tf_idf.sql (hsql_process_text) and agg_funcs/count_shared_terms.sql
--   3) Run hsql_count_shared_terms cases; raise if any got != want
-- #########################################################

\set ON_ERROR_STOP on

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
\set db_name hsql_test
\endif

\if :{?db_user}
\else
\set db_user postgres
\endif

\if :{?db_password}
\else
\set db_password postgres
\endif

\if :{?db_admin_name}
\else
\set db_admin_name postgres
\endif

\setenv PGHOST :db_host
\setenv PGPORT :db_port
\setenv PGUSER :db_user
\setenv PGPASSWORD :db_password

\echo '>>> ensuring database exists: ' :db_name
\connect :db_admin_name
SELECT format('CREATE DATABASE %I', :'db_name')
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = :'db_name'
)\gexec
\connect :db_name

\echo '>>> tf_idf/tf_idf.sql (hsql_process_text)'
\ir ../../tf_idf/tf_idf.sql

\echo '>>> agg_funcs/count_shared_terms.sql'
\ir ../count_shared_terms.sql

\echo '>>> running count_shared_terms tests'

DROP TABLE IF EXISTS _count_shared_terms_test_results;
CREATE TEMP TABLE _count_shared_terms_test_results (
    test_id text PRIMARY KEY,
    want integer NOT NULL,
    got integer
);

INSERT INTO _count_shared_terms_test_results (test_id, want, got) VALUES
    (
        'three_terms_three_tuples_min3',
        3,
        (SELECT hsql_count_shared_terms(txt, 3)
         FROM (VALUES
             ('apple banana cherry'),
             ('apple banana cherry'),
             ('apple banana cherry')
         ) AS v(txt))
    ),
    (
        'two_tuples_below_min3',
        0,
        (SELECT hsql_count_shared_terms(txt, 3)
         FROM (VALUES
             ('apple banana cherry'),
             ('apple banana cherry')
         ) AS v(txt))
    ),
    (
        'three_shared_terms_min2_mixed_rows',
        3,
        (SELECT hsql_count_shared_terms(txt, 2)
         FROM (VALUES
             ('apple banana cherry'),
             ('apple banana cherry'),
             ('dog elephant')
         ) AS v(txt))
    ),
    (
        'empty_group',
        0,
        (SELECT hsql_count_shared_terms(txt, 3)
         FROM (SELECT NULL::text AS txt WHERE false) AS v)
    ),
    (
        'once_per_tuple_repeated_token',
        1,
        (SELECT hsql_count_shared_terms(txt, 2)
         FROM (VALUES
             ('apple apple apple'),
             ('apple apple')
         ) AS v(txt))
    ),
    (
        'group_event1_min2',
        1,
        (SELECT hsql_count_shared_terms(txt, 2)
         FROM (VALUES
             ('apple apple apple'),
             ('apple banana'),
             ('apple cherry')
         ) AS v(txt))
    ),
    (
        'null_and_empty_text_ignored',
        0,
        (SELECT hsql_count_shared_terms(txt, 1)
         FROM (VALUES
             (NULL::text),
             ('')
         ) AS v(txt))
    ),
    (
        'combine_merges_partial_states',
        1,
        (SELECT hsql_count_shared_terms_final(
            hsql_count_shared_terms_combine(
                '{"__minimum__": 2, "appl": 2, "banana": 1}'::jsonb,
                '{"__minimum__": 2, "appl": 1, "cherri": 1}'::jsonb
            )
        ))
    ),
    (
        'combine_matches_chained_sfunc',
        3,
        (SELECT hsql_count_shared_terms_final(
            hsql_count_shared_terms_combine(
                hsql_count_shared_terms_sfunc(
                    hsql_count_shared_terms_sfunc('{}'::jsonb, 'apple banana cherry', 2),
                    'apple banana cherry',
                    2
                ),
                hsql_count_shared_terms_sfunc('{}'::jsonb, 'dog elephant', 2)
            )
        ))
    );

INSERT INTO _count_shared_terms_test_results (test_id, want, got)
SELECT
    'group_by_event_id_event' || event_id::text,
    1,
    shared_term_count
FROM (
    SELECT event_id, hsql_count_shared_terms(txt, 2) AS shared_term_count
    FROM (VALUES
        (1, 'apple apple apple'),
        (1, 'apple banana'),
        (1, 'apple cherry'),
        (2, 'dog dog'),
        (2, 'dog cat')
    ) AS e(event_id, txt)
    GROUP BY event_id
) AS per_event;

-- Per-case results (for inspection)
SELECT
    test_id,
    got,
    want,
    (got = want) AS ok
FROM _count_shared_terms_test_results
ORDER BY test_id;

-- Single PASS / FAIL row for automation
SELECT CASE
    WHEN EXISTS (
        SELECT 1
        FROM _count_shared_terms_test_results
        WHERE got IS DISTINCT FROM want
    ) THEN 'FAIL'
    ELSE 'PASS'
END AS count_shared_terms_tests;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM _count_shared_terms_test_results
        WHERE got IS DISTINCT FROM want
    ) THEN
        RAISE EXCEPTION 'count_shared_terms tests failed (see per-case output above)';
    END IF;
END;
$$;

DROP TABLE _count_shared_terms_test_results;

\echo '>>> count_shared_terms tests passed'
