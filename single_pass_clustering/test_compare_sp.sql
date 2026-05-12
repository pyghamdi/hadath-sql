\set ON_ERROR_STOP on

-- Load required helpers and functions.
\ir ../util/table_utils.sql
\ir ../tf_idf/tf_idf.sql
\ir clst_sp_cluster.sql

-- Fresh input corpus for repeatable testing.
DROP TABLE IF EXISTS clst_compare_input CASCADE;
CREATE TABLE clst_compare_input (
    doc_id integer PRIMARY KEY,
    txt text NOT NULL,
    ts timestamp NOT NULL
);

INSERT INTO clst_compare_input (doc_id, txt, ts) VALUES
    (1, 'cat kitten pet food bowl', '2026-01-01 10:00:00'),
    (2, 'dog puppy pet leash park', '2026-01-01 10:01:00'),
    (3, 'cat kitten sleeps on sofa pet', '2026-01-01 10:02:00'),
    (4, 'database sql query index table join', '2026-01-01 10:03:00'),
    (5, 'postgresql query optimization index planner', '2026-01-01 10:04:00'),
    (6, 'deep learning neural network training model', '2026-01-01 10:05:00'),
    (7, 'machine learning model training dataset', '2026-01-01 10:06:00'),
    (8, 'cat dog pet adoption shelter', '2026-01-01 10:07:00');

-- Build TF-IDF once; both clustering variants consume exactly the same vectors.
SELECT hsql_create_tf_idf_tbl(
    'clst_compare_input',
    'doc_id',
    'txt',
    'clst_compare_tfidf',
    TRUE
);

-- Run version 1.
SELECT clst_single_pass_clustering(
    'clst_compare_input',
    'doc_id',
    'ts',
    'clst_compare_v1',
    'clst_compare_tfidf',
    0.1,
    TRUE
);

-- Run version 2.
SELECT clst_single_pass_clustering_v2(
    'clst_compare_input',
    'doc_id',
    'ts',
    'clst_compare_v2',
    'clst_compare_tfidf',
    0.1,
    TRUE
);

DO $$
DECLARE
    diff_clusters bigint;
    diff_assignments bigint;
    diff_centroids bigint;
BEGIN
    -- Compare cluster metadata.
    SELECT COUNT(*) INTO diff_clusters
    FROM (
        (SELECT cid, doc_count FROM clst_compare_v1
         EXCEPT
         SELECT cid, doc_count FROM clst_compare_v2)
        UNION ALL
        (SELECT cid, doc_count FROM clst_compare_v2
         EXCEPT
         SELECT cid, doc_count FROM clst_compare_v1)
    ) d;

    -- Compare document assignments.
    SELECT COUNT(*) INTO diff_assignments
    FROM (
        (SELECT doc_id, cid FROM clst_compare_v1_cluster_assignments
         EXCEPT
         SELECT doc_id, cid FROM clst_compare_v2_cluster_assignments)
        UNION ALL
        (SELECT doc_id, cid FROM clst_compare_v2_cluster_assignments
         EXCEPT
         SELECT doc_id, cid FROM clst_compare_v1_cluster_assignments)
    ) d;

    -- Compare centroids with a strict tolerance for floating-point arithmetic.
    SELECT COUNT(*) INTO diff_centroids
    FROM (
        SELECT
            COALESCE(v1.cid, v2.cid) AS cid,
            COALESCE(v1.term, v2.term) AS term,
            v1.weight AS w1,
            v2.weight AS w2
        FROM clst_compare_v1_centroid v1
        FULL OUTER JOIN clst_compare_v2_centroid v2
            ON v1.cid = v2.cid
           AND v1.term = v2.term
        WHERE v1.cid IS NULL
           OR v2.cid IS NULL
           OR ABS(v1.weight - v2.weight) > 1e-12
    ) d;

    IF diff_clusters > 0 OR diff_assignments > 0 OR diff_centroids > 0 THEN
        RAISE EXCEPTION
            'Mismatch detected. cluster_diffs=%, assignment_diffs=%, centroid_diffs=%',
            diff_clusters, diff_assignments, diff_centroids;
    END IF;
    
    RAISE NOTICE 'PASS: clst_single_pass_clustering and v2 outputs are identical.';
END $$;

-- Optional human-readable snapshots.
TABLE clst_compare_v1 ORDER BY cid;
TABLE clst_compare_v1_cluster_assignments ORDER BY doc_id;
TABLE clst_compare_v1_centroid ORDER BY cid, term;

-- Cleanup: remove all test artifacts created by this script.
DROP TABLE IF EXISTS clst_compare_input CASCADE;
DROP TABLE IF EXISTS clst_compare_v2_cluster_assignments CASCADE;
DROP TABLE IF EXISTS clst_compare_v2_centroid CASCADE;
DROP TABLE IF EXISTS clst_compare_v2 CASCADE;

DROP TABLE IF EXISTS clst_compare_v1_cluster_assignments CASCADE;
DROP TABLE IF EXISTS clst_compare_v1_centroid CASCADE;
DROP TABLE IF EXISTS clst_compare_v1 CASCADE;

DROP TABLE IF EXISTS clst_compare_tfidf CASCADE;