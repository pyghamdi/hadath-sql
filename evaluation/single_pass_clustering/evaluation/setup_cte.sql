-- Definitions used by the array CTE, version (A): a composite type and two SQL
-- functions (non-standard: composite type, arrays, UDFs). Installed once, like
-- HadathSQL itself; not part of any timed run.

-- Helpers for version (A) (non-standard: composite type, arrays, UDFs).
DROP TYPE IF EXISTS hc_cluster CASCADE;
CREATE TYPE hc_cluster AS (cid int, n int, terms text[], ws float8[]);

-- Cosine similarity, computed as in the driver: dot / (||a|| * ||b||), 0 if a norm is 0.
CREATE OR REPLACE FUNCTION hc_cos(at text[], aw float8[], bt text[], bw float8[])
RETURNS float8 LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    (SELECT SUM(a.w * b.w) FROM unnest(at, aw) a(t, w) JOIN unnest(bt, bw) b(t, w) ON a.t = b.t)
    / NULLIF(SQRT(COALESCE((SELECT SUM(x * x) FROM unnest(aw) x), 0.0))
           * SQRT(COALESCE((SELECT SUM(y * y) FROM unnest(bw) y), 0.0)), 0.0),
    0.0)
$$;

-- The branch: fold the document into c_best (running-mean centroid, drop zero weights)
-- if similar enough, otherwise append a new cluster seeded with the document.
CREATE OR REPLACE FUNCTION hc_assign(dt text[], dw float8[], cs hc_cluster[],
                                     best hc_cluster, best_sim float8, th float8)
RETURNS hc_cluster[] LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN best IS NOT NULL AND COALESCE(best_sim, 0.0) >= th THEN
      (SELECT array_agg(
                CASE WHEN c.cid = best.cid THEN
                  (SELECT ROW(best.cid, best.n + 1,
                              COALESCE(array_agg(m.t ORDER BY m.t), '{}'),
                              COALESCE(array_agg(m.w ORDER BY m.t), '{}'))::hc_cluster
                   FROM (SELECT COALESCE(o.t, d.t) AS t,
                                (COALESCE(o.w, 0.0) * best.n + COALESCE(d.w, 0.0)) / (best.n + 1.0) AS w
                         FROM unnest(best.terms, best.ws) o(t, w)
                         FULL OUTER JOIN unnest(dt, dw) d(t, w) ON o.t = d.t) m
                   WHERE m.w > 0.0)
                ELSE ROW(c.cid, c.n, c.terms, c.ws)::hc_cluster END
              ORDER BY c.cid)
       FROM unnest(cs) c)
    ELSE cs || ROW(COALESCE(cardinality(cs), 0) + 1, 1, dt, dw)::hc_cluster
  END
$$;
