/* #########################################################
Clustering Usage Example
This file demonstrates how to use the clst_single_pass_clustering function
######################################################### */

SELECT hsql_create_tf_idf_tbl(
  'test_data', 
  'doc_id', 
  'txt', 
  'tfidf_test_data', 
  TRUE
);
SELECT * FROM tfidf_test_data;

SELECT clst_single_pass_clustering(
  'test_data',
  'doc_id',
  'ts',
  'cluster_test_data',
  'tfidf_test_data',
  0.5,
  TRUE
);
SELECT * FROM cluster_test_data;
SELECT * 
FROM cluster_test_data_cluster_assignments
JOIN test_data ON test_data.doc_id = cluster_test_data_cluster_assignments.doc_id
WHERE cluster_test_data_cluster_assignments.cid = 2;

SELECT * FROM tfidf_test_data WHERE doc_id = 1;
SELECT * FROM cluster_test_data_centroid WHERE cid = 2;
SELECT * FROM tfidf_test_data WHERE doc_id = 3;
UPDATE cluster_test_data_centroid SET weight = 1.0 WHERE cid = 2;

SELECT update_centroid(2, 3);

CREATE OR REPLACE FUNCTION update_centroid(cid integer, doc_id integer) RETURNS void AS $$
DECLARE
    update_centroid_query text;
    existing_doc_count integer;
    centroid_tbl text := 'cluster_test_data_centroid';
    tfidf_tbl text := 'tfidf_test_data';
    cluster_tbl text := 'cluster_test_data';
BEGIN
    EXECUTE format('SELECT doc_count FROM %I WHERE cid = $1', cluster_tbl)
    INTO existing_doc_count
    USING cid;
    RAISE NOTICE 'existing_doc_count: %', existing_doc_count;
  
    update_centroid_query := format(
          'WITH merged AS (
               SELECT
                   COALESCE(cluster.term, doc.term) AS term,
                   (
                       COALESCE(cluster.weight, 0.0) * COALESCE($3, 0) +
                       COALESCE(doc.weight, 0.0)
                   ) / (COALESCE($3, 0) + 1.0) AS new_weight
               FROM (
                   SELECT term, weight
                   FROM %I
                   WHERE cid = $1
               ) AS cluster
               FULL OUTER JOIN (
                   SELECT term, weight 
                   FROM %I
                   WHERE doc_id = $2
               ) AS doc
               ON cluster.term = doc.term
           ),
           upserted AS (
               INSERT INTO %I (cid, term, weight)
               SELECT $1, m.term, m.new_weight
               FROM merged m
               WHERE m.new_weight > 0.0
               ON CONFLICT (cid, term) DO UPDATE
               SET weight = EXCLUDED.weight
           )
           DELETE FROM %I ct
           WHERE ct.cid = $1
             AND NOT EXISTS (
                 SELECT 1
                 FROM merged m
                 WHERE m.new_weight > 0.0
                   AND m.term = ct.term
             )',
          centroid_tbl,
          tfidf_tbl,
          centroid_tbl,
          centroid_tbl
      );
    
    EXECUTE update_centroid_query USING cid, doc_id, existing_doc_count;

END;
$$ LANGUAGE plpgsql;


CREATE TABLE centroid_norm AS (
  SELECT cid, SUM(weight * weight) AS norm_sq
  FROM output_centroid
  GROUP BY cid
);

SELECT * FROM centroid_norm;

SELECT centroid.cid, SUM(centroid.weight * doc_weights.weight) AS dot_val
-- SELECT *
FROM output_centroid centroid
JOIN doc_weights ON doc_weights.term = centroid.term
GROUP BY centroid.cid
;

DROP TABLE IF EXISTS dot_prod;
CREATE TABLE dot_prod AS (
  SELECT centroid.cid, SUM(centroid.weight * doc_weights.weight) AS dot_product
  FROM output_centroid centroid
  JOIN doc_weights ON doc_weights.term = centroid.term
  GROUP BY centroid.cid
);


SELECT 
  *,
  -- output.cid,
  -- dp.dot_product,
  -- cn.norm_sq AS centroid_norm_sq,
  -- dn.norm_sq AS doc_norm_sq,
  COALESCE(
    dp.dot_product / NULLIF(SQRT(cn.norm_sq) * SQRT(dn.norm_sq), 0.0),
    0.0
  ) AS cosine_sim
FROM output -- output table
LEFT JOIN centroid_norm cn ON cn.cid = output.cid
LEFT JOIN dot_prod dp ON dp.cid = output.cid
CROSS JOIN doc_norm dn
ORDER BY cosine_sim DESC, output.cid
-- LIMIT 1
;


/*
output table (cid, doc_count)
LEFT JOIN centroid_norm table (cid, norm_sq)
LEFT JOIN dot_prod table (cid, dot_product)
CROSS JOIN doc_norm table (norm_sq)
*/

WITH doc_vec AS (
  SELECT term, tf_idf AS weight
  FROM tfidf_test_model
  WHERE doc_id = 1
), doc_norm AS (
  SELECT COALESCE(SUM(weight * weight), 0.0) AS norm_sq
  FROM doc_vec
) 
SELECT * FROM doc_norm;



SELECT * FROM doc_vec;
doc_norm AS (
             SELECT COALESCE(SUM(weight * weight), 0.0) AS norm_sq
             FROM doc_vec
         ),
doc_norm AS (
  SELECT COALESCE(SUM(weight * weight), 0.0) AS norm_sq
  FROM doc_vec
),
SELECT * FROM doc_norm;

WITH doc_weight AS (
    SELECT term, tf_idf AS weight
    FROM tfidf_sm_dataset
    WHERE doc_id = 1
),
doc_norm AS (
    SELECT COALESCE(SUM(weight * weight), 0.0) AS norm_sq
    FROM doc_weight
),
centroid_norm AS (
    SELECT c.cid, COALESCE(SUM(c.weight * c.weight), 0.0) AS norm_sq
    FROM output_centroid c
    GROUP BY c.cid
),
dot_prod AS (
    SELECT c.cid, SUM(c.weight * d.weight) AS dot_product
    FROM output_centroid c
    JOIN doc_weight d ON d.term = c.term
    GROUP BY c.cid
)
SELECT cn.cid,
       COALESCE(
           dp.dot_product / NULLIF(SQRT(cn.norm_sq) * SQRT(dn.norm_sq), 0.0),
           0.0
       ) AS cosine_sim
FROM centroid_norm cn
CROSS JOIN doc_norm dn
-- LEFT JOIN centroid_norm cn ON cn.cid = o.cid
LEFT JOIN dot_prod dp ON dp.cid = cn.cid
-- FROM output o
-- CROSS JOIN doc_norm dn
-- LEFT JOIN centroid_norm cn ON cn.cid = o.cid
-- LEFT JOIN dot_prod dp ON dp.cid = o.cid
ORDER BY cosine_sim DESC, cn.cid
-- LIMIT 1
;

