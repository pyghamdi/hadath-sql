/* #########################################################
Clustering Usage Example
This file demonstrates how to use the incremental_cluster function
######################################################### */

-- Example 1: Run incremental clustering with default threshold (0.7)
SELECT cls_incremental_clustering('sample_documents', 'text', 'created_at', 'document_frequency_table', 'test_clusters', 0.7, true);

SELECT * FROM cls_get_closest_cluster('some text', 'test_clusters');

-- SELECT * FROM cls_get_closest_cluster('some text', 'test_clusters');
SELECT cls_compute_document_cluster_distance('sample_documents', 'document_id', 1, 1);


-- -- Example 3: View clustering results
-- SELECT * FROM get_clustering_results();

-- -- Example 4: Clear clustering data for fresh start
-- SELECT * FROM clear_clustering_data();

drop function cls_incremental_clustering cascade;