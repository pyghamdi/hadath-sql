"""Generate the ablation variants of the HadathSQL driver from
single_pass_clustering/sp_clustering.sql. Each variant removes exactly one
optimization and is otherwise the HadathSQL driver's code, so rerun this script
whenever sp_clustering.sql changes.

  driver_variant_hadathsql_no_index.sql     hsql_spc_hadathsql_noidx   (key noidx)
  driver_variant_hadathsql_mean.sql         hsql_spc_hadathsql_mean    (key mean)
  driver_variant_hadathsql_no_prepared.sql  hsql_spc_hadathsql_noprep  (key noprep)
  driver_variant_hadathsql_no_optimizations.sql  hsql_spc_hadathsql_noopt  (key noopt):
      all three removals at once, for the combined effect of the optimizations
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "..", "single_pass_clustering", "sp_clustering.sql")


def cut(s, start, end):
    """Text from `start` (inclusive) to the first `end` after it (inclusive)."""
    a = s.index(start)
    return s[a:s.index(end, a) + len(end)]


def sub(s, old, new, count=1):
    assert s.count(old) == count, (old[:70], s.count(old))
    return s.replace(old, new)


def base(fn):
    src = open(SRC).read()
    tbls = cut(src, "CREATE OR REPLACE FUNCTION hsql_create_tbls_for_single_pass_clustering(", "$$ LANGUAGE plpgsql;")
    drv = cut(src, "CREATE OR REPLACE FUNCTION hsql_single_pass_clustering_tfidf(", "SET random_page_cost = 1.1;")
    tbls = sub(tbls, "hsql_create_tbls_for_single_pass_clustering", fn + "_tbls")
    drv = sub(drv, "hsql_create_tbls_for_single_pass_clustering", fn + "_tbls")
    drv = sub(drv, "hsql_single_pass_clustering_tfidf(", fn + "(")
    return tbls, drv


def no_index(tbls, drv):
    # No index on the TF-IDF table's doc_id (the experiment passes an unindexed copy,
    # and the driver no longer creates the index) and no term index on the centroid
    # table. The primary keys stay: the upsert needs the one on (cid, term).
    tbls = sub(tbls, "    -- Term index: finds the clusters that share a term with a document.\n"
                     "    EXECUTE format('CREATE INDEX ON %I (term, cid)', centroid_tbl);\n\n", "")
    drv = sub(drv, cut(drv, "    -- Each iteration reads one document's vector; make sure an index on doc_id",
                       "    END IF;\n"), "")
    return tbls, drv


def mean(tbls, drv):
    # Running-mean centroids instead of summed ones: the cluster table stores the norm
    # of the mean; adding a document rewrites every entry of the centroid; no final
    # division.
    tbls = sub(tbls, "            norm float NOT NULL DEFAULT 0.0,\n            sum_sq_norm float NOT NULL DEFAULT 0.0\n",
                     "            norm float NOT NULL DEFAULT 0.0\n")
    drv = sub(drv, "c.prod / NULLIF(a_norm.norm * SQRT(r.sum_sq_norm), 0.0)", "c.prod / NULLIF(a_norm.norm * r.norm, 0.0)")
    old_add = cut(drv, "    -- Add the document with id $2 to cluster $1, in one statement:", "    );\n")
    drv = sub(drv, old_add, """    -- Add the document with id $2 to cluster $1, in one statement (mean centroids):
    --   cl       = the cluster size n before this document.
    --   merged   = the new running mean (n * old + doc) / (n + 1) of every term of the
    --              centroid or of the document's positive weights. All parts of the
    --              statement see the same snapshot, so merged reads the old centroid.
    --   upserted = write every entry of the new mean (the whole centroid is rewritten).
    --              Weights are positive, so no entry ever falls to 0.
    --   assigned = record the assignment.
    --   UPDATE   = increment doc_count and store the norm of the new mean.
    add_document_query := format(
        'WITH cl AS (
             SELECT doc_count AS n FROM %I WHERE cid = $1
         ),
         merged AS (
             SELECT
                 COALESCE(cluster.term, doc.term) AS term,
                 (COALESCE(cluster.weight, 0.0) * cl.n + COALESCE(doc.weight, 0.0))
                     / (cl.n + 1.0) AS new_weight
             FROM (
                 SELECT term, weight FROM %I WHERE cid = $1
             ) AS cluster
             FULL OUTER JOIN (
                 SELECT term, weight FROM %I WHERE doc_id = $2 AND weight > 0.0
             ) AS doc
             ON cluster.term = doc.term
             CROSS JOIN cl
         ),
         upserted AS (
             INSERT INTO %I AS ct (cid, term, weight)
             SELECT $1, term, new_weight FROM merged
             ON CONFLICT (cid, term) DO UPDATE
             SET weight = EXCLUDED.weight
         ),
         assigned AS (
             INSERT INTO %I (doc_id, cid) VALUES ($2, $1)
         )
         UPDATE %I
         SET doc_count = doc_count + 1,
             norm = (SELECT SQRT(COALESCE(SUM(new_weight * new_weight), 0.0)) FROM merged)
         WHERE cid = $1',
        output_tbl,
        centroid_tbl,
        tfidf_tbl,
        centroid_tbl,
        assignments_tbl,
        output_tbl
    );
""")
    drv = sub(drv, cut(drv, "    -- Turn the summed centroids into mean centroids, and their norms accordingly.",
                       "DROP COLUMN sum_sq_norm', output_tbl);\n"), "")
    return tbls, drv


def no_prepared(tbls, drv):
    # Dynamic statements executed with EXECUTE ... USING, parsed and planned at every
    # execution, instead of being prepared once per call.
    dealloc = ("    FOR stmt_name IN\n        SELECT name FROM pg_prepared_statements WHERE name LIKE 'hsql\\_spc\\_%'\n"
               "    LOOP\n        EXECUTE format('DEALLOCATE %I', stmt_name);\n    END LOOP;\n")
    drv = sub(drv, "    -- Prepared statements live for the whole session; drop any left behind by an\n"
                   "    -- earlier call that failed before it could deallocate them.\n" + dealloc, "")
    drv = sub(drv, "    -- Release the prepared statements.\n" + dealloc, "")
    drv = sub(drv, cut(drv, "    -- Prepare every per-document statement once.", "add_document_query);\n"), "")
    drv = sub(drv, "EXECUTE format('EXECUTE hsql_spc_best(%s)', doc_id)\n            INTO most_similar_cluster_id, max_similarity;",
                   "EXECUTE best_cluster_query\n            INTO most_similar_cluster_id, max_similarity\n            USING doc_id;")
    drv = sub(drv, "EXECUTE 'EXECUTE hsql_spc_new_cluster' INTO assigned_cluster_id;",
                   "EXECUTE new_cluster_query INTO assigned_cluster_id;")
    drv = sub(drv, "EXECUTE format('EXECUTE hsql_spc_add_document(%s, %s)', assigned_cluster_id, doc_id);",
                   "EXECUTE add_document_query USING assigned_cluster_id, doc_id;")
    for leftover in ("hsql_spc_best", "hsql_spc_new_cluster", "hsql_spc_add_document", "pg_prepared_statements"):
        assert leftover not in drv, leftover
    return tbls, drv


VARIANTS = [
    ("driver_variant_hadathsql_no_index.sql", "hsql_spc_hadathsql_noidx", no_index,
     "HadathSQL driver without indexes: no index on the TF-IDF table's doc_id (the\n"
     "-- experiment passes an unindexed copy) and no term index on the centroid table, so\n"
     "-- every document scans both tables. The primary keys stay (the upsert needs the one\n"
     "-- on (cid, term)), and so do the stored norms, statistics refresh, random_page_cost,\n"
     "-- summed centroids, prepared and merged statements, and fill factor 80."),
    ("driver_variant_hadathsql_mean.sql", "hsql_spc_hadathsql_mean", mean,
     "HadathSQL driver without summed centroids: centroids stored as running means, so\n"
     "-- adding a document rewrites the whole centroid and recomputes its norm from it.\n"
     "-- Everything else as in the HadathSQL driver: indexes, statistics refresh,\n"
     "-- random_page_cost, prepared and merged statements, fill factor 80."),
    ("driver_variant_hadathsql_no_prepared.sql", "hsql_spc_hadathsql_noprep", no_prepared,
     "HadathSQL driver without prepared statements: the per-document statements are run\n"
     "-- with EXECUTE ... USING, so they are parsed and planned at every execution.\n"
     "-- Everything else as in the HadathSQL driver: summed centroids, indexes, stored\n"
     "-- norms, statistics refresh, random_page_cost, merged statements, fill factor 80."),
    ("driver_variant_hadathsql_no_optimizations.sql", "hsql_spc_hadathsql_noopt",
     lambda t, d: no_prepared(*mean(*no_index(t, d))),
     "HadathSQL driver without all three optimizations: no\n"
     "-- indexes (the experiment passes an unindexed copy of the TF-IDF table), running-mean\n"
     "-- centroids, and no prepared statements, i.e. the three removals of the other\n"
     "-- variants applied together. Everything else as in the HadathSQL driver: stored norms,\n"
     "-- statistics refresh, random_page_cost, merged statements, fill factor 80."),
]

for path, fn, change, desc in VARIANTS:
    tbls, drv = change(*base(fn))
    head = (f"-- GENERATED by make_ablation_variants.py from single_pass_clustering/sp_clustering.sql;\n"
            f"-- do not edit by hand. {desc}\n"
            f"-- Installed as {fn} (tables via {fn}_tbls), with the signature of\n"
            f"-- hsql_single_pass_clustering_tfidf. Comments are the HadathSQL driver's and may\n"
            f"-- mention what this variant removes.\n\n")
    with open(os.path.join(HERE, path), "w") as f:
        f.write(head + tbls + "\n\n\n" + drv + "\n")
    print("wrote", path)
