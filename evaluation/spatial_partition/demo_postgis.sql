-- =====================================================
-- Demo: PostGIS-based spatial partitioning functions
-- (space_partition_postgis.sql)
-- =====================================================
--
-- hsql_spatial_partition_postgis  scalar function, used in SELECT and GROUP BY
-- hsql_spatial_partition_lateral  set-returning function, used with CROSS JOIN LATERAL
--
-- Both return the same cell as hsql_spatial_partition (space_partition.sql),
-- which is shown next to them for comparison.
--
-- Prerequisites, in this order:
--   CREATE EXTENSION postgis;
--   \i spatial_partition/space_partition.sql
--   \i evaluation/spatial_partition/space_partition_postgis.sql
--
-- Run (from repository root):
--   psql -d <database> -f evaluation/spatial_partition/demo_postgis.sql
--
-- Section 5 calls hsql_spatial_partition with wrong cell lengths and is
-- expected to print ERROR messages; psql continues with the next statement.
-- The expected results are noted above each query.

-- =====================================================
-- 1. One point, three functions
-- =====================================================
-- A point in Makkah (Web Mercator meters), 1-km cells.
-- Expected: (4433,2442) from all three.
SELECT hsql_spatial_partition(4433432.30, 2442329.09, 1000)          AS udf,
       hsql_spatial_partition_postgis(4433432.30, 2442329.09, 1000)  AS postgis_scalar,
       (SELECT (p.x, p.y)
        FROM hsql_spatial_partition_lateral(4433432.30, 2442329.09, 1000) AS p) AS postgis_lateral;

-- =====================================================
-- 2. Shifted grids
-- =====================================================
-- The point lies 432 m east and 329 m north of its cell's south-west corner.
-- Shifting the grid 500 m east and north moves that corner past the point,
-- so the point falls in the cell to the south-west.
-- Expected: (4432,2441) from all three.
SELECT hsql_spatial_partition(4433432.30, 2442329.09, 1000, 500, 500)          AS udf,
       hsql_spatial_partition_postgis(4433432.30, 2442329.09, 1000, 500, 500)  AS postgis_scalar,
       (SELECT (p.x, p.y)
        FROM hsql_spatial_partition_lateral(4433432.30, 2442329.09, 1000, 500, 500) AS p) AS postgis_lateral;

-- Shifting 500 m west and south keeps the point in the same cell.
-- Expected: (4433,2442) from all three.
SELECT hsql_spatial_partition(4433432.30, 2442329.09, 1000, -500, -500)          AS udf,
       hsql_spatial_partition_postgis(4433432.30, 2442329.09, 1000, -500, -500)  AS postgis_scalar,
       (SELECT (p.x, p.y)
        FROM hsql_spatial_partition_lateral(4433432.30, 2442329.09, 1000, -500, -500) AS p) AS postgis_lateral;

-- =====================================================
-- 3. Negative cell indices
-- =====================================================
-- The grid origin is (0, 0), so cells west of the prime meridian and south of
-- the equator have negative indices. A point in Sao Paulo, 100-km cells.
-- Expected: (-52,-27) from all three.
SELECT hsql_spatial_partition(-5191324.26, -2698929.26, 100000)          AS udf,
       hsql_spatial_partition_postgis(-5191324.26, -2698929.26, 100000)  AS postgis_scalar,
       (SELECT (p.x, p.y)
        FROM hsql_spatial_partition_lateral(-5191324.26, -2698929.26, 100000) AS p) AS postgis_lateral;

-- =====================================================
-- 4. Grouping a table of points
-- =====================================================
CREATE TEMP TABLE demo_docs (id integer, x double precision, y double precision);
INSERT INTO demo_docs VALUES
    (1, 4433432.30, 2442329.09),   -- cell (4433,2442)
    (2, 4433900.00, 2442050.00),   -- cell (4433,2442)
    (3, 4433100.00, 2442999.99),   -- cell (4433,2442), 1 cm below the cell's upper edge
    (4, 4434000.00, 2442500.00),   -- cell (4434,2442), exactly on the edge between two cells
    (5, 4434700.00, 2442600.00),   -- cell (4434,2442)
    (6, 4433500.00, 2443400.00);   -- cell (4433,2443)

-- Scalar function in SELECT and GROUP BY, as with hsql_spatial_partition.
-- Expected: (4433,2442) 3, (4433,2443) 1, (4434,2442) 2
SELECT hsql_spatial_partition_postgis(x, y, 1000) AS cell, COUNT(*) AS n
FROM demo_docs
GROUP BY cell
ORDER BY cell;

-- Lateral function in FROM; PostgreSQL inlines it into a lateral join on ST_SquareGrid.
-- Expected: the same three groups.
SELECT p.x, p.y, COUNT(*) AS n
FROM demo_docs AS d
CROSS JOIN LATERAL hsql_spatial_partition_lateral(d.x, d.y, 1000) AS p
GROUP BY p.x, p.y
ORDER BY p.x, p.y;

-- Every point is assigned to exactly one cell, including point 3 (1 cm below
-- an edge) and point 4 (exactly on an edge).
-- Expected: one row per point, cells_per_point = 1, same_as_udf = true.
SELECT d.id, COUNT(*) AS cells_per_point,
       bool_and((p.x, p.y)::spatial_partition_id = hsql_spatial_partition(d.x, d.y, 1000)) AS same_as_udf
FROM demo_docs AS d
CROSS JOIN LATERAL hsql_spatial_partition_lateral(d.x, d.y, 1000) AS p
GROUP BY d.id
ORDER BY d.id;

-- =====================================================
-- 5. Wrong cell lengths
-- =====================================================
-- The PostGIS-based functions do not check cell_length. For a cell length that
-- ST_SquareGrid cannot use, it returns no square, so the scalar function returns
-- NULL and the lateral function returns no row. Neither raises an error.
-- Expected:
--   zero, negative, NULL, too small, NaN, Infinity -> scalar NULL, 0 lateral rows
--   fractional 1500.5                              -> (2954,1627), 1 lateral row
--   larger than the world, 1e12                    -> (0,0), 1 lateral row
SELECT label,
       cell_length,
       hsql_spatial_partition_postgis(4433432.30, 2442329.09, cell_length) AS postgis_scalar,
       (SELECT COUNT(*)
        FROM hsql_spatial_partition_lateral(4433432.30, 2442329.09, cell_length)) AS postgis_lateral_rows
FROM (VALUES
        ('zero',                  0::numeric),
        ('negative',              -1000),
        ('NULL',                  NULL),
        ('too small',             0.000001),
        ('NaN',                   'NaN'),
        ('Infinity',              'Infinity'),
        ('fractional',            1500.5),
        ('larger than the world', 1e12)
     ) AS cases(label, cell_length);

-- What this means for a query: with a cell length of 0, the scalar function puts
-- every point into a single NULL group, and the lateral join silently drops
-- every point. Neither result signals that the input was wrong.
-- Expected: one row, cell NULL, n = 6.
SELECT hsql_spatial_partition_postgis(x, y, 0) AS cell, COUNT(*) AS n
FROM demo_docs
GROUP BY cell;

-- Expected: 0 rows.
SELECT p.x, p.y, COUNT(*) AS n
FROM demo_docs AS d
CROSS JOIN LATERAL hsql_spatial_partition_lateral(d.x, d.y, 0) AS p
GROUP BY p.x, p.y;

-- For comparison, hsql_spatial_partition rejects every one of these cell lengths
-- that cannot be used. With a constant cell length, the error is raised while the
-- query is planned, before any row is read.
-- Expected: ERROR "cell_length must be a positive finite number (got 0)"
SELECT hsql_spatial_partition(4433432.30, 2442329.09, 0);
-- Expected: ERROR "cell_length must be a positive finite number (got -1000)"
SELECT hsql_spatial_partition(4433432.30, 2442329.09, -1000);
-- Expected: ERROR "cell_length must be a positive finite number (got <NULL>)"
SELECT hsql_spatial_partition(4433432.30, 2442329.09, NULL);
-- Expected: ERROR "cell_length must be a positive finite number (got NaN)"
SELECT hsql_spatial_partition(4433432.30, 2442329.09, 'NaN');
-- Expected: ERROR "cell_length must be a positive finite number (got Infinity)"
SELECT hsql_spatial_partition(4433432.30, 2442329.09, 'Infinity');
-- A positive but tiny cell length passes the check; the cell index then does not
-- fit in an integer.
-- Expected: ERROR "integer out of range"
SELECT hsql_spatial_partition(4433432.30, 2442329.09, 0.000001);
-- The same check applied to a whole table, with the error raised once.
-- Expected: ERROR "cell_length must be a positive finite number (got 0)"
SELECT hsql_spatial_partition(x, y, 0) AS cell, COUNT(*) AS n
FROM demo_docs
GROUP BY cell;

DROP TABLE demo_docs;
