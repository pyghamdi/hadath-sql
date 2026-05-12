-- #########################################################
-- Parity test: TF-IDF table from tf_idf.sql vs python/tf_idf.py (same tokenizer + formulas).
--
-- HOW TO RUN
--   From the repository root (required so \! python3 tf_idf/python/... resolves):
--
--     psql -v ON_ERROR_STOP=1 -U postgres -f tf_idf/tests/test_sql_vs_python_parity.sql
--
--   Override connection defaults with psql -v (see table below). Example:
--
--     psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5432 -U postgres \
--       -v db_host=127.0.0.1 \
--       -v db_port=5432 \
--       -v db_name=hsql_dev_test \
--       -v db_user=postgres \
--       -v db_password=secret \
--       -v db_admin_name=postgres \
--       -f tf_idf/tests/test_sql_vs_python_parity.sql
--
--   IMPORTANT: psql -v db_user=... does NOT change who psql logs in as. -v only sets script variables. Unless you pass -U / PGUSER / a URI, psql uses your OS login name as the PostgreSQL role, so you get a password prompt for that role—not for postgres. Use -U postgres (and -h/-p as needed) so the session role matches db_user. Subsequent \connect commands keep the same role unless you use \connect db user. To avoid a password prompt, set PGPASSWORD or use ~/.pgpass (same password as db_password if you use role postgres for both psql and Python).
--
--   You may also point psql at a server with PGHOST/PGPORT etc.; this script still sets PGHOST/PGPORT/PGUSER/PGPASSWORD from the variables below for the Python subprocess. PGDATABASE is set to db_name before Python runs.
--
-- DEFAULTS (used when a -v variable is omitted)
--   db_host        127.0.0.1     Server host for \setenv and Python.
--   db_port        5432          Server port.
--   db_name        hsql_dev_test Target database (created if missing; see below).
--   db_user        postgres      Role for connections and Python (PGUSER).
--   db_password    postgres      Password for Python (PGPASSWORD).
--   db_admin_name  postgres      Maintenance DB for first \connect; used only to create db_name if it does not exist.
--
-- PREREQUISITES
--   - Python 3 with psycopg2 (tf_idf/python/generate_sql_python_parity_reference.py).
--   - Role must be allowed to connect and create db_name if it does not exist.
--
-- FLOW
--   1) Ensure db_name exists (connect db_admin_name, CREATE DATABASE if needed).
--   2) Load UDFs from ../tf_idf.sql
--   3) Build corpus table tfidf_parity_corpus
--   4) Python → tfidf_from_python; SQL hsql_create_tf_idf_tbl → tfidf_from_sql
--   5) Compare keys and weights; then DROP test tables.
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
\set db_name hsql_dev_test
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

\echo '>>> tf_idf.sql (UDFs)'
\ir ../tf_idf.sql

DROP TABLE IF EXISTS tfidf_parity_corpus CASCADE;
CREATE TABLE tfidf_parity_corpus (
    doc_id INTEGER PRIMARY KEY,
    txt TEXT NOT NULL
);

INSERT INTO tfidf_parity_corpus (doc_id, txt) VALUES
    (1, 'cat kitten pet food bowl'),
    (2, 'dog puppy pet leash park'),
    (3, 'cat kitten sleeps on sofa pet'),
    (4, 'database sql query index table join'),
    (5, 'postgresql query optimization index planner');

\echo '>>> Python: populate tfidf_from_python (python/tf_idf.py + hsql_process_text)'
\setenv PGDATABASE :db_name
\! python3 tf_idf/python/generate_sql_python_parity_reference.py

\echo '>>> SQL: hsql_create_tf_idf_tbl -> tfidf_from_sql'
SELECT hsql_create_tf_idf_tbl(
    'tfidf_parity_corpus',
    'doc_id',
    'txt',
    'tfidf_from_sql',
    TRUE
);

-- Row counts
SELECT
    (SELECT COUNT(*) FROM tfidf_from_python) AS python_rows,
    (SELECT COUNT(*) FROM tfidf_from_sql) AS sql_rows;

-- Keys present in one side but not the other (expect 0 rows total)
(
    SELECT doc_id, term FROM tfidf_from_python
    EXCEPT
    SELECT doc_id, term FROM tfidf_from_sql
)
UNION ALL
(
    SELECT doc_id, term FROM tfidf_from_sql
    EXCEPT
    SELECT doc_id, term FROM tfidf_from_python
);

-- Per-term weight differences above tolerance (expect 0 rows)
SELECT
    p.doc_id,
    p.term,
    p.weight AS python_weight,
    s.weight AS sql_weight,
    ABS(p.weight - s.weight) AS abs_diff
FROM tfidf_from_python AS p
JOIN tfidf_from_sql AS s
    ON s.doc_id = p.doc_id
   AND s.term = p.term
WHERE ABS(p.weight - s.weight) > 1e-9
ORDER BY abs_diff DESC, p.doc_id, p.term;

-- Single PASS / FAIL row for automation
SELECT CASE
    WHEN EXISTS (
        SELECT 1
        FROM tfidf_from_python AS p
        FULL OUTER JOIN tfidf_from_sql AS s
            ON s.doc_id = p.doc_id
           AND s.term = p.term
        WHERE p.doc_id IS NULL
           OR s.doc_id IS NULL
           OR (p.doc_id IS NOT NULL AND s.doc_id IS NOT NULL AND ABS(p.weight - s.weight) > 1e-9)
    ) THEN 'DIFFERENT'
    ELSE 'MATCH'
END AS sql_vs_python_tfidf;

-- Cleanup temporary test tables.
DROP TABLE IF EXISTS tfidf_from_python;
DROP TABLE IF EXISTS tfidf_from_sql;
DROP TABLE IF EXISTS tfidf_parity_corpus;
