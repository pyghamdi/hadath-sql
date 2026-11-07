-- Array CTE (non-standard; formerly A): the whole cluster set packed into one array.
-- Each iteration also records the cluster of the document it processed (cid).
-- Writes the assignments to cte_array_out(did, cid). Threshold: psql variable :th.
DROP TABLE IF EXISTS cte_array_out;
CREATE TABLE cte_array_out AS
WITH RECURSIVE sp(i, did, cid, clusters) AS (
  SELECT 0, 0, 0, CAST('{}' AS hc_cluster[])
  UNION ALL
  SELECT sp.i + 1,
         d.did,
         CASE WHEN b.c IS NOT NULL AND COALESCE(b.s, 0.0) >= :th
              THEN (b.c).cid ELSE COALESCE(cardinality(sp.clusters), 0) + 1 END,
         hc_assign(d.terms, d.ws, sp.clusters, b.c, b.s, :th)
  FROM sp
  JOIN cte_docs_arr d ON d.rn = sp.i + 1
  LEFT JOIN LATERAL (            -- c_best: highest cosine, ties to the newest cluster
    SELECT c, hc_cos(d.terms, d.ws, c.terms, c.ws) AS s
    FROM unnest(sp.clusters) c
    WHERE cardinality(c.terms) > 0
    ORDER BY s DESC, c.cid DESC
    LIMIT 1
  ) b ON TRUE
)
SELECT did, cid FROM sp WHERE i > 0;
