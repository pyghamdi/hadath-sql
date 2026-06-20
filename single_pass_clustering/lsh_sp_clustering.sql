/*
################################################################################
LSH-based single-pass clustering with built-in TF-IDF (lsh_sp_clustering.sql)
################################################################################
A variant of the classic single-pass / leader clustering algorithm in
`sp_clustering.sql` that replaces the O(#clusters) "compare-to-every-centroid"
step with a Locality-Sensitive Hashing (LSH) lookup. TF-IDF weights are
materialized automatically via `hsql_create_tf_idf_tbl` (from `tf_idf/tf_idf.sql`)
into `<output_tbl>_tfidf` before clustering runs. Cosine similarity is the
target metric, so we use the standard random-hyperplane (SimHash) family:

  - We pick `num_planes` random hyperplanes h_0, ..., h_{K-1} implicitly: for
    each plane i and term t, the deterministic value r_i(t) in {+1, -1} is
    derived from PostgreSQL's `hashtextextended(t, i::bigint)`. This avoids
    storing dense plane vectors over a vocabulary whose size is not known in
    advance, and is reproducible across runs.
  - The signature of a vector v is the K-bit value whose i-th bit is
        bit_i(v) = 1 if sum_t v[t] * r_i(t) >= 0 else 0.
    Two vectors with high cosine similarity have, in expectation, a high
    fraction of matching bits, so they tend to land in the same bucket.
  - Per the random-hyperplane property,
        Pr[bit_i(u) = bit_i(v)] = 1 - angle(u, v) / pi,
    so all-K-bits agreement happens with probability ((pi - theta)/pi)^K.

Algorithm (one pass over documents, ordered by `ts_col`):
  1. First document seeds cluster 1; its TF-IDF vector becomes the centroid
     and the centroid's LSH signature is stored on the cluster row.
  2. For each subsequent document d:
       a. Compute d's K-bit LSH signature from its TF-IDF row set.
       b. Candidate clusters = clusters whose centroid signature == d's
          signature (same LSH bucket). If the bucket is empty, no candidate
          can clear the threshold, so a new cluster is opened immediately.
       c. Otherwise compute cosine similarity between d and each candidate
          centroid; pick the best (c*, sim*).
       d. If sim* >= threshold: assign d to c*, fold d into c*'s centroid via
          the running mean update, and recompute c*'s signature (centroid
          changed -> bucket may move).
       e. Otherwise: open a new cluster seeded with d's TF-IDF vector and
          record its signature.

Storage layout (created by `hsql_create_tbls_for_lsh_single_pass_clustering`):
  <output_tbl>                          (cid SERIAL PK, doc_count INT,
                                         signature BIGINT, INDEX on signature)
  <output_tbl>_centroid                 (cid FK, term, weight, PK(cid, term))
  <output_tbl>_cluster_assignments      (doc_id PK, cid FK)

Public functions:
  hsql_create_tbls_for_lsh_single_pass_clustering(output_tbl, centroid_tbl,
                                                  assignments_tbl,
                                                  overwrite_tbl)
  hsql_lsh_single_pass_clustering(input_tbl, doc_id_col, text_col, ts_col,
                                  output_tbl, threshold, num_planes,
                                  overwrite_output)

Dependencies:
  - `hsql_table_exists_any_schema(text)` from `util/table_utils.sql`
  - `hsql_create_tf_idf_tbl` from `tf_idf/tf_idf.sql`

Notes:
  - Signatures are stored in a single `BIGINT`, so 1 <= num_planes <= 63.
  - Random projections are derived from `hashtextextended(term, plane_id)`,
    which is deterministic; two runs with the same `num_planes` produce the
    same bucketing.
################################################################################
*/

DROP FUNCTION IF EXISTS hsql_create_tbls_for_lsh_single_pass_clustering(text, text, text, boolean) CASCADE;
DROP FUNCTION IF EXISTS hsql_lsh_single_pass_clustering(text, text, text, text, text, float, integer, boolean) CASCADE;


/* ##############################################################################
hsql_create_tbls_for_lsh_single_pass_clustering
--------------------------------------------------------------------------------
Creates (or recreates) the three tables used by LSH-based single-pass
clustering. The schema mirrors `hsql_create_tbls_for_single_pass_clustering`
but the cluster registry carries an extra `signature BIGINT` column (the LSH
signature of the centroid) plus an index on it for fast bucket lookups.

  <output_tbl>          Cluster registry.
                        Columns: cid SERIAL PRIMARY KEY,
                                 doc_count INTEGER,
                                 signature BIGINT.
                        Index:  (signature) for candidate bucket lookups.
  <centroid_tbl>        Cluster centroids in long form.
                        Columns: cid -> output_tbl(cid) ON DELETE CASCADE,
                                 term TEXT, weight FLOAT,
                                 PRIMARY KEY (cid, term).
  <assignments_tbl>     Document-to-cluster assignments.
                        Columns: doc_id INTEGER PRIMARY KEY,
                                 cid -> output_tbl(cid) ON DELETE CASCADE.

Parameters:
  output_tbl       - Name of the cluster registry table to create.
  centroid_tbl     - Name of the centroid table to create.
  assignments_tbl  - Name of the assignments table to create.
  overwrite_tbl    - If TRUE and ANY of the three target tables already
                     exists, drop all three (CASCADE) and recreate them.
                     If FALSE and any of them exists, raise an exception.

Returns: void
############################################################################## */
CREATE OR REPLACE FUNCTION hsql_create_tbls_for_lsh_single_pass_clustering(
    output_tbl text,
    centroid_tbl text,
    assignments_tbl text,
    overwrite_tbl boolean DEFAULT FALSE
)
RETURNS VOID AS $$
DECLARE
    any_exists boolean := hsql_table_exists_any_schema(output_tbl)
                       OR hsql_table_exists_any_schema(centroid_tbl)
                       OR hsql_table_exists_any_schema(assignments_tbl);
BEGIN
    IF any_exists AND NOT overwrite_tbl THEN
        RAISE EXCEPTION
            'One of %, %, % already exists. Set overwrite_tbl=TRUE to overwrite.',
            output_tbl, centroid_tbl, assignments_tbl;
    ELSIF any_exists AND overwrite_tbl THEN
        EXECUTE format('DROP TABLE IF EXISTS %I, %I, %I CASCADE', output_tbl, centroid_tbl, assignments_tbl);
    END IF;

    -- Cluster registry: one row per cluster. `signature` is the SimHash bucket
    -- of the centroid; it is recomputed whenever the centroid changes.
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            cid SERIAL PRIMARY KEY,
            doc_count integer NOT NULL DEFAULT 0,
            signature bigint NOT NULL DEFAULT 0
        )',
        output_tbl
    );

    -- Bucket index: candidate-cluster lookup is a single equality probe on
    -- this index per document.
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I (signature)',
        output_tbl || '_signature_idx',
        output_tbl
    );

    -- Centroid table: long-format (cid, term, weight); one row per term per cluster.
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            cid integer NOT NULL REFERENCES %I(cid) ON DELETE CASCADE,
            term text NOT NULL,
            weight float NOT NULL,
            PRIMARY KEY (cid, term)
        )',
        centroid_tbl,
        output_tbl
    );

    -- Document-to-cluster assignments (each doc belongs to exactly one cluster).
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            doc_id integer PRIMARY KEY,
            cid integer NOT NULL REFERENCES %I(cid) ON DELETE CASCADE
        )',
        assignments_tbl,
        output_tbl
    );
END;
$$ LANGUAGE plpgsql;


/* ##############################################################################
hsql_lsh_single_pass_clustering
--------------------------------------------------------------------------------
Runs single-pass clustering over the documents in `input_tbl`. TF-IDF weights
are built first into `<output_tbl>_tfidf` via `hsql_create_tf_idf_tbl`, then
clustering replaces the "compare to every existing centroid" step with an
LSH bucket lookup. Documents are processed in `ts_col` order. For each
document we (1) compute a K-bit SimHash signature from its TF-IDF vector,
(2) look up only the centroids that share that signature, and (3) run the
usual cosine-similarity comparison on this (typically small) candidate set.

Parameters:
  input_tbl         - Source document table (drives iteration order). Must
                      contain `doc_id_col`, `text_col`, and `ts_col` columns.
  doc_id_col        - Column in `input_tbl` holding the document id (INTEGER).
  text_col          - Column in `input_tbl` holding document text for TF-IDF.
  ts_col            - Column in `input_tbl` used to ORDER BY when iterating.
  output_tbl        - Base name for the output tables (see below).
  threshold         - Minimum cosine similarity in [0, 1] required to attach
                      a document to an existing cluster instead of opening a
                      new one. Default 0.7.
  num_planes        - Number of random hyperplanes K used to build the LSH
                      signature. Must be in [1, 63] so the signature fits in
                      a BIGINT. Larger K => stricter buckets (higher
                      precision, lower recall, more clusters). Default 16.
  overwrite_output  - If TRUE, drop and recreate output tables (including
                      `<output_tbl>_tfidf`) when they already exist; otherwise
                      raise. Default FALSE.

Side effects (tables created / populated):
  <output_tbl>_tfidf                 TF-IDF weights (doc_id, term, weight).
  <output_tbl>                       Cluster registry (cid, doc_count, signature).
  <output_tbl>_centroid              Per-cluster term weights.
  <output_tbl>_cluster_assignments   doc_id -> cid mapping.

Signature construction:
  For each plane i in [0, K) and each term t, define
      r_i(t) = +1 if hashtextextended(t, i::bigint) >= 0 else -1.
  Projection of vector v onto plane i:
      proj_i(v) = sum_t v[t] * r_i(t).
  Bit i of the signature:
      bit_i(v) = 1 if proj_i(v) >= 0 else 0.
  Signature: sum_i bit_i(v) * 2^i (an unsigned K-bit BIGINT).

Cosine similarity (only over candidates in the same bucket):
                          sum_t  a_t * b_t
        sim(a, b) = ------------------------------
                    sqrt(sum_t a_t^2) * sqrt(sum_t b_t^2)

Centroid update (running mean over the n documents already in the cluster):
        new_weight(term) = (old_weight * n + doc_weight) / (n + 1)
  After folding the document into the centroid, the centroid's signature is
  recomputed and the cluster row is updated, since changing the centroid can
  move it to a different LSH bucket.

Returns: void

Notes:
  - The signature is stored on the cluster row and indexed, so the candidate
    lookup is a single equality probe per document (not a full scan).
  - When the bucket is empty (a common early-iteration case) we skip cosine
    computation entirely and open a new cluster.
  - Random projections come from `hashtextextended`, which is deterministic,
    so the same `num_planes` always yields the same bucketing.
  - Tie-breaks between equally similar candidate clusters go to the largest
    `cid` (most recently created cluster), matching `hsql_single_pass_clustering`.
  - `<output_tbl>_tfidf` is built once at the start and read during clustering;
    it is not modified after creation.
############################################################################## */
CREATE OR REPLACE FUNCTION hsql_lsh_single_pass_clustering(
    input_tbl text,
    doc_id_col text,
    text_col text,
    ts_col text,
    output_tbl text,
    threshold float DEFAULT 0.7,
    num_planes integer DEFAULT 16,
    overwrite_output boolean DEFAULT FALSE
)
RETURNS VOID AS $$
DECLARE
    -- Prepared (formatted) dynamic SQL statements; built once and reused per doc.
    retrieve_documents_query text;  -- Iterates doc ids from input_tbl in ts_col order.
    doc_signature_query text;       -- Computes the LSH signature of a document ($1 = doc_id).
    centroid_signature_query text;  -- Computes the LSH signature of a centroid ($1 = cid).
    best_cluster_query text;        -- Returns (cid, similarity) of the closest candidate cluster.
    update_centroid_query text;     -- Folds a document into an existing centroid.
    seed_cluster_query text;        -- INSERT new cluster row with signature $1, RETURNING cid.
    seed_centroid_query text;       -- Copy a document's TF-IDF vector as a new centroid.
    insert_assignment_query text;   -- Record (doc_id, cid) in the assignments table.
    get_doc_count_query text;       -- Read doc_count for a given cluster.
    bump_doc_count_query text;      -- Increment doc_count by 1 for a given cluster.
    update_signature_query text;    -- Refresh the signature of a cluster after a centroid update.

    -- Derived table names.
    tfidf_tbl text := output_tbl || '_tfidf';
    centroid_tbl text := output_tbl || '_centroid';
    assignments_tbl text := output_tbl || '_cluster_assignments';

    -- Loop state.
    doc_id integer;                 -- Current document id from input_tbl.
    doc_count integer := 0;         -- Number of documents processed so far.
    doc_signature bigint;           -- LSH signature of the current document.
    new_signature bigint;           -- Recomputed signature of an updated centroid.
    assigned_cluster_id integer;    -- cid the current document ended up in.
    most_similar_cluster_id integer;-- Best-matching cluster for the current document.
    max_similarity float;           -- Similarity to most_similar_cluster_id.
    existing_doc_count integer;     -- doc_count of the target cluster BEFORE adding this doc.
    final_cluster_count integer;    -- Number of clusters at completion (for the final NOTICE).
BEGIN
    RAISE NOTICE 'Building TF-IDF table %...', tfidf_tbl;
    PERFORM hsql_create_tf_idf_tbl(input_tbl, doc_id_col, text_col, tfidf_tbl, overwrite_output);

    -- Signatures are packed into a BIGINT (63 usable bits + sign), so cap K.
    IF num_planes < 1 OR num_planes > 63 THEN
        RAISE EXCEPTION 'num_planes must be between 1 and 63 (got %).', num_planes;
    END IF;

    RAISE NOTICE 'Creating output tables %, %, %...', output_tbl, centroid_tbl, assignments_tbl;
    PERFORM hsql_create_tbls_for_lsh_single_pass_clustering(output_tbl, centroid_tbl, assignments_tbl, overwrite_output);

    -- Drive the main loop: stream document ids in the requested chronological order.
    retrieve_documents_query := format(
        'SELECT %I FROM %I ORDER BY %I',
        doc_id_col, input_tbl, ts_col
    );

    -- Compute the K-bit LSH signature for the document whose id is bound to $1.
    --   planes        = 0..K-1, one row per random hyperplane.
    --   projections   = projection of the doc vector onto each plane, where
    --                   r_i(t) is recovered from the sign bit of
    --                   hashtextextended(term, plane_id::bigint).
    --   The outer SELECT folds the K {0,1} bits into a single BIGINT.
    -- COALESCE handles documents with no terms in tfidf_tbl (signature = 0).
    doc_signature_query := format(
        'WITH planes AS (
             SELECT generate_series(0, %s - 1) AS plane_id
         ),
         projections AS (
             SELECT p.plane_id,
                    SUM(t.weight * CASE
                            WHEN hashtextextended(t.term, p.plane_id::bigint) < 0
                                THEN -1.0
                            ELSE 1.0
                        END) AS proj
             FROM %I t
             CROSS JOIN planes p
             WHERE t.doc_id = $1
             GROUP BY p.plane_id
         )
         SELECT COALESCE(SUM(
                    CASE WHEN COALESCE(proj, 0.0) >= 0
                         THEN (1::bigint << plane_id)
                         ELSE 0::bigint
                    END
                ), 0)::bigint
         FROM projections',
        num_planes,
        tfidf_tbl
    );

    -- Same computation but reads from the centroid table for cluster $1.
    -- Used to (re)compute a cluster''s bucket after its centroid changes.
    centroid_signature_query := format(
        'WITH planes AS (
             SELECT generate_series(0, %s - 1) AS plane_id
         ),
         projections AS (
             SELECT p.plane_id,
                    SUM(c.weight * CASE
                            WHEN hashtextextended(c.term, p.plane_id::bigint) < 0
                                THEN -1.0
                            ELSE 1.0
                        END) AS proj
             FROM %I c
             CROSS JOIN planes p
             WHERE c.cid = $1
             GROUP BY p.plane_id
         )
         SELECT COALESCE(SUM(
                    CASE WHEN COALESCE(proj, 0.0) >= 0
                         THEN (1::bigint << plane_id)
                         ELSE 0::bigint
                    END
                ), 0)::bigint
         FROM projections',
        num_planes,
        centroid_tbl
    );

    -- Pick the best-matching cluster from the candidate set (clusters in the
    -- same LSH bucket as the document). $1 = doc_id, $2 = doc_signature.
    --   a          = tfidf_tbl rows for the current document (doc vector).
    --   candidates = cids whose centroid signature == doc signature (bucket).
    --   b          = centroid_tbl rows restricted to those candidates.
    -- Cosine similarity is computed only against candidates; ties broken by
    -- larger cid for determinism. If the bucket is empty this returns no row.
    best_cluster_query := format(
        'WITH a AS (
             SELECT term, weight
             FROM %I
             WHERE doc_id = $1
         ),
         a_norm AS (
             SELECT SQRT(COALESCE(SUM(weight * weight), 0.0)) AS norm
             FROM a
         ),
         candidates AS (
             SELECT cid
             FROM %I
             WHERE signature = $2
         ),
         b_norm AS (
             SELECT b.cid, SQRT(COALESCE(SUM(b.weight * b.weight), 0.0)) AS norm
             FROM %I b
             JOIN candidates USING (cid)
             GROUP BY b.cid
         ),
         dot_val AS (
             SELECT b.cid, SUM(a.weight * b.weight) AS prod
             FROM a
             JOIN %I b ON a.term = b.term
             JOIN candidates ON candidates.cid = b.cid
             GROUP BY b.cid
         )
         SELECT b_norm.cid,
                COALESCE(
                    dot_val.prod / NULLIF(a_norm.norm * b_norm.norm, 0.0),
                    0.0
                ) AS sim
         FROM a_norm
         CROSS JOIN b_norm
         LEFT JOIN dot_val ON dot_val.cid = b_norm.cid
         ORDER BY sim DESC, b_norm.cid DESC
         LIMIT 1',
        tfidf_tbl,
        output_tbl,
        centroid_tbl,
        centroid_tbl
    );

    -- Update the centroid of cluster $1 by folding in document $2.
    -- $3 is the cluster's doc_count BEFORE this document is added, so the new
    -- centroid weight for each term is the running mean:
    --     new = (old * $3 + doc_weight) / ($3 + 1)
    -- Terms whose new weight is 0 are removed from the centroid table.
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

    -- Small per-iteration statements: pre-format once to avoid rebuilding
    -- identifier-quoted SQL inside the hot loop. The cluster row is created
    -- with the centroid's signature ($1) so the bucket index is populated
    -- immediately and the very next document can find it.
    seed_cluster_query := format(
        'INSERT INTO %I (doc_count, signature) VALUES (1, $1) RETURNING cid',
        output_tbl
    );
    seed_centroid_query := format(
        'INSERT INTO %I (cid, term, weight)
         SELECT $1, term, weight
         FROM %I
         WHERE doc_id = $2',
        centroid_tbl,
        tfidf_tbl
    );
    insert_assignment_query := format(
        'INSERT INTO %I (doc_id, cid) VALUES ($1, $2)',
        assignments_tbl
    );
    get_doc_count_query := format(
        'SELECT doc_count FROM %I WHERE cid = $1',
        output_tbl
    );
    bump_doc_count_query := format(
        'UPDATE %I SET doc_count = doc_count + 1 WHERE cid = $1',
        output_tbl
    );
    update_signature_query := format(
        'UPDATE %I SET signature = $2 WHERE cid = $1',
        output_tbl
    );

    RAISE NOTICE '########################################################';
    RAISE NOTICE 'Starting LSH single-pass clustering (K=% planes)...', num_planes;
    RAISE NOTICE '########################################################';

    FOR doc_id IN EXECUTE retrieve_documents_query
    LOOP
        -- Hash the incoming document into its LSH bucket once per iteration.
        EXECUTE doc_signature_query INTO doc_signature USING doc_id;

        IF doc_count = 0 THEN
            -- First document: seed cluster 1 unconditionally with its signature.
            EXECUTE seed_cluster_query INTO assigned_cluster_id USING doc_signature;
            EXECUTE seed_centroid_query USING assigned_cluster_id, doc_id;
            EXECUTE insert_assignment_query USING doc_id, assigned_cluster_id;
        ELSE
            -- Only compare against centroids that share the document's bucket.
            -- If the bucket is empty this leaves max_similarity NULL and we
            -- fall through to the new-cluster branch without scanning others.
            most_similar_cluster_id := NULL;
            max_similarity := NULL;
            EXECUTE best_cluster_query
            INTO most_similar_cluster_id, max_similarity
            USING doc_id, doc_signature;

            -- COALESCE guards both an empty bucket and degenerate all-zero norms.
            IF COALESCE(max_similarity, 0.0) >= threshold THEN
                -- Attach to existing cluster: update centroid (running mean),
                -- bump doc_count, record the assignment, and refresh the
                -- cluster's LSH signature (the centroid just moved).
                assigned_cluster_id := most_similar_cluster_id;

                EXECUTE get_doc_count_query
                INTO existing_doc_count
                USING assigned_cluster_id;

                EXECUTE update_centroid_query
                USING assigned_cluster_id, doc_id, existing_doc_count;

                EXECUTE bump_doc_count_query USING assigned_cluster_id;
                EXECUTE insert_assignment_query USING doc_id, assigned_cluster_id;

                EXECUTE centroid_signature_query
                INTO new_signature
                USING assigned_cluster_id;
                EXECUTE update_signature_query USING assigned_cluster_id, new_signature;
            ELSE
                -- Bucket empty or below threshold: open a new cluster seeded
                -- with this document. The seed centroid's signature is the
                -- document's signature, so we reuse doc_signature directly.
                EXECUTE seed_cluster_query INTO assigned_cluster_id USING doc_signature;
                EXECUTE seed_centroid_query USING assigned_cluster_id, doc_id;
                EXECUTE insert_assignment_query USING doc_id, assigned_cluster_id;
            END IF;
        END IF;

        doc_count := doc_count + 1;
    END LOOP;

    EXECUTE format('SELECT COUNT(*) FROM %I', output_tbl) INTO final_cluster_count;
    RAISE NOTICE 'Completed. Documents processed: %, clusters created: %', doc_count, final_cluster_count;
END;
$$ LANGUAGE plpgsql;
