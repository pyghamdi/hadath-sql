-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- Spatial partitioning (space_partition.sql)
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- Divides the Web Mercator plane (EPSG:3857) into a regular grid of square
-- cells and maps a point to the cell that contains it. The cell is returned as
-- a partition identifier that can be used directly in GROUP BY.
--
-- Defines:
--   spatial_partition_id                          type: (x, y) indices of a grid cell
--   hsql_spatial_partition(x, y, cell_length [, s_x, s_y])
--
-- Parameters of hsql_spatial_partition:
--   x            x coordinate of the point in Web Mercator, in meters
--   y            y coordinate of the point in Web Mercator, in meters
--   cell_length  side length of a grid cell, in meters; must be positive and finite
--   s_x          optional shift of the grid along the x axis, in meters (default 0)
--   s_y          optional shift of the grid along the y axis, in meters (default 0)
--
-- Returns: spatial_partition_id (x, y), where
--   x = floor((x - s_x) / cell_length) and y = floor((y - s_y) / cell_length).
--
-- Examples:
--   -- Cell of one point on a 1 km grid: returns (1,-1)
--   SELECT hsql_spatial_partition(1500, -200, 1000);
--
--   -- Number of documents in each 1 km cell
--   SELECT hsql_spatial_partition(x, y, 1000) AS cell, COUNT(*)
--   FROM docs
--   GROUP BY cell;
--
--   -- The same grid moved by half a cell in both directions
--   SELECT hsql_spatial_partition(x, y, 1000, 500, 500) AS cell, COUNT(*)
--   FROM docs
--   GROUP BY cell;
--
-- Notes:
--   - The grid origin is the origin (0, 0) of the Web Mercator coordinate system,
--     so cell indices are negative west of the prime meridian and south of the
--     equator.
--   - A positive s_x moves the grid in the +x direction and a positive s_y moves
--     it in the +y direction; negative shifts move it the other way.
--   - A point on a cell edge belongs to the cell on its upper (greater x or y) side.
--   - The coordinates are assumed to be valid Web Mercator coordinates; they are
--     not checked. Longitude/latitude values must be converted to Web Mercator
--     before the call.
--   - An invalid cell_length (zero, negative, NaN, or infinite) raises an error.

-- Identifier of a grid cell: the x and y indices of the cell in the grid.
CREATE TYPE spatial_partition_id AS (
	x integer,
	y integer
);

-- Raises the error for an invalid cell_length; called only when the check in
-- hsql_spatial_partition fails. It is declared IMMUTABLE so that a constant
-- invalid cell_length is reported once, while the query is planned.
CREATE OR REPLACE FUNCTION hsql_invalid_cell_length(cell_length numeric)
  RETURNS spatial_partition_id
AS $$
BEGIN
  RAISE EXCEPTION 'cell_length must be a positive finite number (got %)', cell_length;
END;
$$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- The function is a single SQL expression so that PostgreSQL can inline it into
-- the calling query. When cell_length is a constant, as in
-- hsql_spatial_partition(x, y, 1000), the planner evaluates the cell_length
-- check once and the query computes only the two floor expressions per row.
-- Inlining stops if the function becomes STRICT, gets a SET clause, or its body
-- is no longer a single expression; keep that in mind when editing it.
CREATE OR REPLACE FUNCTION hsql_spatial_partition(
  x float,
  y float,
  cell_length numeric,
  s_x numeric DEFAULT 0,
  s_y numeric DEFAULT 0
) RETURNS spatial_partition_id
AS $$
  -- NaN compares greater than every number, so the upper bound also rejects it.
  -- Subtracting the shift moves the grid lines in the direction of the shift vector.
  SELECT CASE
    WHEN cell_length > 0 AND cell_length < 'Infinity' THEN
      ROW(floor((x - COALESCE(s_x, 0)) / cell_length),
          floor((y - COALESCE(s_y, 0)) / cell_length))::spatial_partition_id
    ELSE hsql_invalid_cell_length(cell_length)
  END
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
