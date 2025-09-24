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

-- Python-based spatial partition function (alternative implementation)
-- This function uses Python for the calculation (requires plpython3u extension)
CREATE OR REPLACE FUNCTION py_spatial_partition(x float, y float, cell_length int)
  RETURNS spatial_partition_id
AS $$
# Web Mercator projection bounds (EPSG:3857)
x_min = -20037508
y_min = -20037508
return (int((x - x_min) // cell_length), int((y - y_min) // cell_length))
$$ LANGUAGE plpython3u;

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
CREATE OR REPLACE FUNCTION spatial_partition(x float, y float, cell_length numeric)
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
