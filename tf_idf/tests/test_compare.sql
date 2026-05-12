-- #########################################################
-- Compare the iterative TF-IDF table builder with the reference TF-IDF table builder.
-- Prerequisite: dataset table `test_data(doc_id, txt)` exists and has at least one document.
-- #########################################################

-- Cleanup old outputs (if any).
DROP TABLE IF EXISTS tfidf_tbl_itr;
DROP TABLE IF EXISTS tfidf_tbl_ref;

-- 1) Build iterative TF-IDF output.
SELECT hsql_create_tf_idf_tbl_itr(
    'test_data',
    'txt',
    'doc_id',
    'tfidf_tbl_itr',
    TRUE
);

-- 2) Build reference TF-IDF output from tf_idf.sql.
SELECT hsql_create_tf_idf_tbl(
    'test_data',
    'doc_id',
    'txt',
    'tfidf_tbl_ref',
    TRUE
);

-- Quick visual check for one document.
SELECT * FROM tfidf_tbl_itr WHERE doc_id = 1 ORDER BY weight DESC, term;
SELECT * FROM tfidf_tbl_ref WHERE doc_id = 1 ORDER BY weight DESC, term;

-- 3) Sanity checks on iterative output.
-- Terms with invalid numeric values (should return zero rows).
SELECT *
FROM tfidf_tbl_itr
WHERE weight IS NULL
   OR weight::text = 'NaN'
   OR weight::text = 'Infinity'
   OR weight::text = '-Infinity';

-- Duplicate key check (doc_id, term) in iterative output (should return zero rows).
SELECT
    doc_id,
    term,
    COUNT(*) AS dup_count
FROM tfidf_tbl_itr
GROUP BY doc_id, term
HAVING COUNT(*) > 1;

-- 4) Parity checks between iterative and reference outputs.
-- 4.1 Row-count comparison.
SELECT
    (SELECT COUNT(*) FROM tfidf_tbl_itr) AS itr_rows,
    (SELECT COUNT(*) FROM tfidf_tbl_ref) AS ref_rows;

-- 4.2 Key-set parity: (doc_id, term) must match exactly (should return zero rows).
(
    SELECT doc_id, term FROM tfidf_tbl_itr
    EXCEPT
    SELECT doc_id, term FROM tfidf_tbl_ref
)
UNION ALL
(
    SELECT doc_id, term FROM tfidf_tbl_ref
    EXCEPT
    SELECT doc_id, term FROM tfidf_tbl_itr
);

-- 4.3 Weight parity with floating-point tolerance (should return zero rows).
SELECT
    i.doc_id,
    i.term,
    i.weight AS itr_weight,
    r.weight AS ref_weight,
    ABS(i.weight - r.weight) AS abs_diff
FROM tfidf_tbl_itr AS i
JOIN tfidf_tbl_ref AS r
    ON r.doc_id = i.doc_id
   AND r.term = i.term
WHERE ABS(i.weight - r.weight) > 1e-12
ORDER BY abs_diff DESC, i.doc_id, i.term;

-- 4.4 Final pass/fail status.
SELECT CASE
    WHEN EXISTS (
        SELECT 1
        FROM tfidf_tbl_itr AS i
        FULL OUTER JOIN tfidf_tbl_ref AS r
            ON r.doc_id = i.doc_id
           AND r.term = i.term
        WHERE i.doc_id IS NULL
           OR r.doc_id IS NULL
           OR ABS(i.weight - r.weight) > 1e-12
    ) THEN 'DIFFERENT'
    ELSE 'MATCH'
END AS comparison_status;

