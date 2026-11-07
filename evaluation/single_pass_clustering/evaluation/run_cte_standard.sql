-- Standard SQL CTE (formerly C): the standard-SQL baseline. Clusters kept as rows;
-- only a recursive CTE, window functions,
-- joins, CASE, and CAST (no arrays, no custom types, no UDFs).
-- Implements the driver's algorithm: TF-IDF cosine similarity, ties to the newest
-- cluster, running-mean centroid update that drops zero weights, new clusters
-- seeded with the document's full vector.
-- State rows (i, kind, cid, term, w, cnt, did) after i documents:
--   'T' centroid entry (cid, term, w)    'K' cluster size (cid, cnt)
--   'M' assignment (cid, did)            'S' sentinel (keeps the state non-empty)
-- Writes the assignments to cte_rows_out(did, cid). Threshold: psql variable :th.
DROP TABLE IF EXISTS cte_rows_out;
CREATE TABLE cte_rows_out AS
WITH RECURSIVE sp(i, kind, cid, term, w, cnt, did) AS (
  SELECT 0, CAST('S' AS varchar(1)), 0, CAST(NULL AS varchar(200)),
         CAST(NULL AS double precision), 0, 0
  UNION ALL
  SELECT f.i + 1,
         CAST(CASE
           WHEN k.n = 1 AND f.kind IN ('T', 'K', 'M', 'S') THEN f.kind
           WHEN k.n = 1 AND f.kind = 'D' THEN 'T'
           WHEN k.n = 2 AND f.kind = 'S' THEN 'M'
           WHEN k.n = 3 AND f.kind = 'S' THEN 'K'
         END AS varchar(1)),
         CASE
           WHEN k.n = 1 AND f.kind IN ('T', 'K', 'M', 'S') THEN f.cid
           ELSE f.tcid
         END,
         CAST(f.term AS varchar(200)),
         CASE
           WHEN k.n = 1 AND f.kind = 'T' AND f.att = 1 AND f.cid = f.bestcid
             THEN (f.w * f.bestn + COALESCE(f.dw, 0.0)) / (f.bestn + 1.0)
           WHEN k.n = 1 AND f.kind = 'D' AND f.att = 1
             THEN (0.0 * f.bestn + f.w) / (f.bestn + 1.0)
           ELSE f.w
         END,
         CASE
           WHEN k.n = 1 AND f.kind = 'K' AND f.att = 1 AND f.cid = f.bestcid THEN f.cnt + 1
           WHEN k.n = 3 THEN 1
           ELSE f.cnt
         END,
         f.did
  FROM (
    SELECT e.*,
           CASE WHEN e.att = 1 THEN e.bestcid ELSE COALESCE(e.maxcid, 0) + 1 END AS tcid,
           MAX(CASE WHEN e.kind = 'K' AND e.cid = e.bestcid THEN e.cnt END) OVER () AS bestn,
           MAX(CASE WHEN e.kind = 'T' AND e.cid = e.bestcid THEN 1 ELSE 0 END)
             OVER (PARTITION BY e.term) AS in_best
    FROM (
      SELECT d.*,
             FIRST_VALUE(d.cid) OVER (ORDER BY d.simt DESC NULLS LAST, d.cid DESC) AS bestcid,
             CASE WHEN MAX(d.simt) OVER () >= :th THEN 1 ELSE 0 END AS att,
             MAX(CASE WHEN d.kind = 'K' THEN d.cid END) OVER () AS maxcid
      FROM (
        SELECT c.*,
               CASE WHEN c.kind = 'T'
                    THEN COALESCE(c.dot / NULLIF(c.anorm * c.bnorm, 0.0), 0.0) END AS simt
        FROM (
          SELECT b.*,
                 SUM(CASE WHEN b.kind = 'T' THEN b.w * b.dw END) OVER (PARTITION BY b.cid) AS dot,
                 SQRT(SUM(CASE WHEN b.kind = 'T' THEN b.w * b.w END) OVER (PARTITION BY b.cid)) AS bnorm
          FROM (
            SELECT a.*,
                   MAX(CASE WHEN a.kind = 'D' THEN a.w END) OVER (PARTITION BY a.term) AS dw,
                   SQRT(COALESCE(SUM(CASE WHEN a.kind = 'D' THEN a.w * a.w END) OVER (), 0.0)) AS anorm
            FROM (
              -- the sentinel is joined with the next document: one 'S' row carrying
              -- the document id, plus one 'D' row per term of the document
              SELECT sp.i,
                     CASE WHEN sp.kind = 'S' THEN x.kind ELSE sp.kind END AS kind,
                     sp.cid,
                     CASE WHEN sp.kind = 'S' THEN x.term ELSE sp.term END AS term,
                     CASE WHEN sp.kind = 'S' THEN x.w ELSE sp.w END AS w,
                     sp.cnt,
                     CASE WHEN sp.kind = 'S' THEN x.did ELSE sp.did END AS did
              FROM sp
              LEFT JOIN (
                SELECT v.rn, CAST('D' AS varchar(1)) AS kind, v.term, v.w, 0 AS did FROM cte_vec v
                UNION ALL
                SELECT o.rn, 'S', NULL, NULL, o.did FROM cte_docs o
              ) x ON sp.kind = 'S' AND x.rn = sp.i + 1
              WHERE sp.i < (SELECT COUNT(*) FROM cte_docs)
            ) a
          ) b
        ) c
      ) d
    ) e
  ) f
  CROSS JOIN (VALUES (1), (2), (3)) AS k(n)
  WHERE (k.n = 1 AND f.kind IN ('K', 'M', 'S'))
     OR (k.n = 1 AND f.kind = 'T'
         AND NOT (f.att = 1 AND f.cid = f.bestcid
                  AND (f.w * f.bestn + COALESCE(f.dw, 0.0)) / (f.bestn + 1.0) <= 0.0))
     OR (k.n = 1 AND f.kind = 'D' AND f.att = 0)
     OR (k.n = 1 AND f.kind = 'D' AND f.att = 1 AND f.in_best = 0
         AND (0.0 * f.bestn + f.w) / (f.bestn + 1.0) > 0.0)
     OR (k.n = 2 AND f.kind = 'S')
     OR (k.n = 3 AND f.kind = 'S' AND f.att = 0)
)
SELECT did, cid FROM sp
WHERE kind = 'M' AND i = (SELECT MAX(i) FROM sp);
