/* #########################################################
Clustering Usage Example
This file demonstrates how to use the incremental_cluster function
######################################################### */
-- Example 1: Run incremental clustering with default threshold (0.7)
SELECT
    cls_incremental_clustering('sample_documents', 'content', 'created_at', 'my_tfidf_model', 'test_clusters', 0.7, TRUE);

SELECT
    *
FROM
    test_clusters;

-- Cosine distance between two vectors
-- vector1: (word1, 0.5), (word2, 0.3)
-- vector2: (word1, 0.4), (word3, 0.2)
-- result should be 0.233
SELECT
    cls_cosine_distance(ARRAY[ROW ('word1', 0.5)::tfidf_term_weight, ROW ('word2', 0.3)::tfidf_term_weight], ARRAY[ROW ('word1', 0.4)::tfidf_term_weight, ROW ('word3', 0.2)::tfidf_term_weight]);

