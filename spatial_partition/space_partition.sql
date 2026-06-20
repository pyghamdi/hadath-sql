-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- Spatial Partitioning Functions for Web Mercator Projection (EPSG:3857)
-- Returns grid cell coordinates for spatial partitioning
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

drop type if exists spatial_partition_id cascade;

-- Create a custom type for spatial partition coordinates
-- This type stores the x and y coordinates of a grid cell
CREATE TYPE spatial_partition_id AS (
	x integer,
	y integer
);

-- -- Python-based spatial partition function (alternative implementation)
-- -- This function uses Python for the calculation (requires plpython3u extension)
-- CREATE OR REPLACE FUNCTION hsql_py_spatial_partition(x float, y float, cell_length int)
--   RETURNS spatial_partition_id
-- AS $$
-- # Web Mercator projection bounds (EPSG:3857)
-- x_min = -20037508
-- y_min = -20037508
-- return (int((x - x_min) // cell_length), int((y - y_min) // cell_length))
-- $$ LANGUAGE plpython3u;

-- Main spatial partition function (PostgreSQL implementation)
-- Divides Web Mercator projection into a regular grid and returns grid cell coordinates
-- 
-- Parameters:
--   x: x coordinate in Web Mercator projection (meters)
--   y: y coordinate in Web Mercator projection (meters)
--   cell_length: length of each grid cell in meters
--
-- Returns: spatial_partition_id with (x_cell, y_cell) coordinates
--
-- Note: Grid origin is at (-20037508, -20037508) which corresponds to
--       Web Mercator projection bounds (EPSG:3857)
DROP FUNCTION IF EXISTS spatial_partition(float, float, numeric) CASCADE;
DROP FUNCTION IF EXISTS hsql_spatial_partition(float, float, numeric) CASCADE;

CREATE OR REPLACE FUNCTION hsql_spatial_partition(x float, y float, cell_length numeric)
  RETURNS spatial_partition_id
AS $$
DECLARE
  x_min float := -20037508.34;  -- Web Mercator projection bounds
  y_min float := -20037508.34;  -- Web Mercator projection bounds
BEGIN
  RETURN (
    floor((x - x_min) / cell_length),
    floor((y - y_min) / cell_length)
  )::spatial_partition_id;
END;
$$ LANGUAGE plpgsql;

-- Shifted spatial partitioning (square grid offset after computing cells)
--
-- Parameters:
--   x, y: coordinates in Web Mercator projection (meters)
--   cell_length: length of each grid cell in meters
--   s_x: shift along the Web Mercator x axis (longitude axis), in cell units
--   s_y: shift along the Web Mercator y axis (latitude axis), in cell units
--
-- Notes:
--   - Positive s_x moves partitions in +x direction.
--   - Positive s_y moves partitions in +y direction.
--   - Negative shifts are allowed (grid can be shifted in any direction).
DROP FUNCTION IF EXISTS spatial_partition_shifted(float, float, numeric, integer, integer) CASCADE;
DROP FUNCTION IF EXISTS hsql_spatial_partition_shifted(float, float, numeric, integer, integer) CASCADE;

CREATE OR REPLACE FUNCTION hsql_spatial_partition_shifted(
  x float,
  y float,
  cell_length numeric,
  s_x integer,
  s_y integer
) RETURNS spatial_partition_id
AS $$
DECLARE
  x_min float := -20037508.34;  -- Web Mercator projection bounds
  y_min float := -20037508.34;  -- Web Mercator projection bounds
  x_cell integer;
  y_cell integer;
BEGIN
  x_cell := floor((x - x_min + s_x) / cell_length)::integer;
  y_cell := floor((y - y_min + s_y) / cell_length)::integer;
  RETURN (x_cell, y_cell)::spatial_partition_id;
END;
$$ LANGUAGE plpgsql;
