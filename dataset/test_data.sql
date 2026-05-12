-- #########################################################
-- Create datas tables
-- #########################################################

CREATE TABLE IF NOT EXISTS test_data(
    doc_id SERIAL PRIMARY KEY,
    txt TEXT,
    ts TIMESTAMP DEFAULT NULL
);

SELECT pg_size_pretty(pg_total_relation_size('test_data')) as total_size, pg_size_pretty(pg_relation_size('test_data')) as table_size;

-- #########################################################
-- Quick checks for test_data
-- #########################################################

-- 1) Row count
SELECT COUNT(*) AS row_count
FROM test_data;

-- 2) Time range and null timestamp count
SELECT
    MIN(ts) AS min_ts,
    MAX(ts) AS max_ts,
    COUNT(*) FILTER (WHERE ts IS NULL) AS null_ts_count
FROM test_data;

-- 3) Sample rows
SELECT doc_id, ts, LEFT(txt, 120) AS txt_preview
FROM test_data
ORDER BY doc_id
LIMIT 10;

WITH d AS (
  SELECT *
  FROM "1K_doc"
  WHERE doc_id = (SELECT MIN(doc_id) FROM "1K_doc")
)
SELECT
  doc_id,
  (
    SELECT COUNT(*)::bigint
    FROM regexp_split_to_table(COALESCE(txt, ''), E'\s+') AS w(word)
    WHERE word <> ''
  ) AS word_count
FROM d;