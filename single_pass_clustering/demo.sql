-- Run single-pass clustering over the 100 rows in test_data.
-- The function creates test_sp_clusters_tfidf, test_sp_clusters_clusters,
-- test_sp_clusters_summed_centroids, and test_sp_clusters_assignments.
SELECT hsql_single_pass_clustering(
		'test_data',
		'doc_id',
		'txt',
		'ts',
		'test_sp_clusters',
		0.7,
		TRUE
);

-- Cluster summary.
SELECT cid, doc_count
FROM test_sp_clusters_clusters
ORDER BY cid;

-- Document-to-cluster assignments in processing order.
SELECT d.doc_id, d.ts, a.cid
FROM test_data AS d
JOIN test_sp_clusters_assignments AS a
	ON a.doc_id = d.doc_id
ORDER BY d.ts, d.doc_id;
