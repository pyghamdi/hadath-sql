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
--   s_x: optional shift of the grid along the Web Mercator x axis (longitude axis), in meters (default 0)
--   s_y: optional shift of the grid along the Web Mercator y axis (latitude axis), in meters (default 0)
--
-- Returns: spatial_partition_id with (x_cell, y_cell) coordinates
--
-- Notes:
--   - Grid origin is at (-20037508.34, -20037508.34) which corresponds to
--     Web Mercator projection bounds (EPSG:3857)
--   - Positive s_x moves the grid in the +x direction.
--   - Positive s_y moves the grid in the +y direction.
--   - Negative shifts are allowed (grid can be shifted in any direction).
DROP FUNCTION IF EXISTS hsql_validate_web_mercator_coords(float, float) CASCADE;

-- Validates that x/y are finite coordinates within EPSG:3857 (Web Mercator) bounds.
CREATE OR REPLACE FUNCTION hsql_validate_web_mercator_coords(x float, y float)
  RETURNS void
AS $$
DECLARE
  x_extent float := 20037508.342789244;  -- half world width in meters
  y_extent float := 20048966.104014636;  -- max |y| at latitude ±85.05112877980659°
BEGIN
  IF x <> x OR y <> y THEN
    RAISE EXCEPTION 'Web Mercator coordinates must be finite numbers (got x=%, y=%)', x, y;
  END IF;

  IF abs(x) = 'Infinity'::float OR abs(y) = 'Infinity'::float THEN
    RAISE EXCEPTION 'Web Mercator coordinates must be finite numbers (got x=%, y=%)', x, y;
  END IF;

  IF x < -x_extent OR x > x_extent THEN
    RAISE EXCEPTION 'x coordinate % is outside valid Web Mercator range [%, %]',
      x, -x_extent, x_extent;
  END IF;

  IF y < -y_extent OR y > y_extent THEN
    RAISE EXCEPTION 'y coordinate % is outside valid Web Mercator range [%, %]',
      y, -y_extent, y_extent;
  END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

DROP FUNCTION IF EXISTS spatial_partition(float, float, numeric) CASCADE;
DROP FUNCTION IF EXISTS spatial_partition_shifted(float, float, numeric, integer, integer) CASCADE;
-- Shifting used to live in a separate function; it is now part of hsql_spatial_partition.
DROP FUNCTION IF EXISTS hsql_spatial_partition_shifted(float, float, numeric, numeric, numeric) CASCADE;
DROP FUNCTION IF EXISTS hsql_spatial_partition(float, float, numeric) CASCADE;
DROP FUNCTION IF EXISTS hsql_spatial_partition(float, float, numeric, numeric, numeric) CASCADE;

CREATE OR REPLACE FUNCTION hsql_spatial_partition(
  x float,
  y float,
  cell_length numeric,
  s_x numeric DEFAULT 0,
  s_y numeric DEFAULT 0
) RETURNS spatial_partition_id
AS $$
DECLARE
  x_min float := -20037508.34;  -- Web Mercator projection bounds
  y_min float := -20037508.34;  -- Web Mercator projection bounds
BEGIN
  PERFORM hsql_validate_web_mercator_coords(x, y);

  IF cell_length IS NULL OR cell_length <= 0 THEN
    RAISE EXCEPTION 'cell_length must be a positive number (got %)', cell_length;
  END IF;

  -- Subtracting the shift moves the grid lines in the direction of the shift vector.
  RETURN (
    floor(((x - x_min) - COALESCE(s_x, 0)) / cell_length),
    floor(((y - y_min) - COALESCE(s_y, 0)) / cell_length)
  )::spatial_partition_id;
END;
$$ LANGUAGE plpgsql;
