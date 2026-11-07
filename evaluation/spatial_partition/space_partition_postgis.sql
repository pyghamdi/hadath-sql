-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- Spatial partitioning implemented on top of PostGIS ST_SquareGrid
-- (experimental alternative to hsql_spatial_partition in space_partition.sql)
--
-- Requires the PostGIS extension and space_partition.sql (for the
-- spatial_partition_id type). Not loaded by install.sql.
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- Both functions return the same cell as hsql_spatial_partition for the same
-- arguments. ST_SquareGrid and hsql_spatial_partition both align the grid to
-- the coordinate origin (0, 0). ST_SquareGrid has no shift parameters, so the
-- shift is applied to the point instead of the grid: shifting the grid by
-- (s_x, s_y) is the same as shifting the point by (-s_x, -s_y).
--
-- ST_SquareGrid called on a single point returns the square containing it and,
-- for a point within float precision of an edge, a neighboring square too.
-- The ST_Intersects test keeps only the square that contains the point.
--
-- Like hsql_spatial_partition, these functions assume valid Web Mercator
-- coordinates. Unlike it, they do not check that cell_length > 0.

-- Scalar variant: drop-in replacement, callable in SELECT and GROUP BY.
--
--   SELECT hsql_spatial_partition_postgis(x, y, 1000) AS p FROM docs GROUP BY p;
DROP FUNCTION IF EXISTS hsql_spatial_partition_postgis(float, float, numeric, numeric, numeric) CASCADE;

CREATE OR REPLACE FUNCTION hsql_spatial_partition_postgis(
  x float,
  y float,
  cell_length numeric,
  s_x numeric DEFAULT 0,
  s_y numeric DEFAULT 0
) RETURNS spatial_partition_id
AS $$
  SELECT (g.i, g.j)::spatial_partition_id
  FROM (SELECT ST_MakePoint(x - COALESCE(s_x, 0), y - COALESCE(s_y, 0)) AS p) AS t
  CROSS JOIN LATERAL ST_SquareGrid(cell_length::float, t.p) AS g
  WHERE ST_Intersects(t.p, g.geom);
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Set-returning variant: for use in the FROM clause with a lateral join.
-- PostgreSQL can inline it into the calling query, so the query runs as a
-- lateral join on ST_SquareGrid itself.
--
--   SELECT p.x, p.y
--   FROM docs AS d CROSS JOIN LATERAL hsql_spatial_partition_lateral(d.x, d.y, 1000) AS p
--   GROUP BY p.x, p.y;
DROP FUNCTION IF EXISTS hsql_spatial_partition_lateral(float, float, numeric, numeric, numeric) CASCADE;

CREATE OR REPLACE FUNCTION hsql_spatial_partition_lateral(
  x float,
  y float,
  cell_length numeric,
  s_x numeric DEFAULT 0,
  s_y numeric DEFAULT 0
) RETURNS TABLE (x integer, y integer)
AS $$
  SELECT g.i, g.j
  FROM (SELECT ST_MakePoint($1 - COALESCE($4, 0), $2 - COALESCE($5, 0)) AS p) AS t
  CROSS JOIN LATERAL ST_SquareGrid($3::float, t.p) AS g
  WHERE ST_Intersects(t.p, g.geom);
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
