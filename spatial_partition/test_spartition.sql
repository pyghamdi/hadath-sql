-- Test the spatial_partition function with Saudi cities
-- Using 50km x 50km grid cells (50,000 meters)
-- Coordinates are in Web Mercator projection (EPSG:3857)

SELECT 'Makkah' AS City, * FROM spatial_partition(4433432.304231072, 2442329.093011221, 50000);

SELECT 'Jeddah' AS City, * FROM spatial_partition(4362889.142915375, 2449900.2161562047, 50000);

SELECT 'Riyadh' AS City, * FROM spatial_partition(5195870.628623282, 2840607.6257099737, 50000);

SELECT 'Dammam' AS City, * FROM spatial_partition(5572108.243606389, 3051889.530698993, 50000);

SELECT COUNT(*) as "number of cities", spatial_partition, array_agg(City) AS cities
FROM (
    SELECT 'Makkah' AS City, spatial_partition(4433432.30, 2442329.09, 500000)
    UNION ALL
    SELECT 'Jeddah' AS City, spatial_partition(4362889.14, 2449900.21, 500000)
    UNION ALL
    SELECT 'Riyadh' AS City, spatial_partition(5195870.62, 2840607.62, 500000)
    UNION ALL
    SELECT 'Dammam' AS City, spatial_partition(5572108.24, 3051889.53, 500000)
    UNION ALL
    SELECT 'Almadina' AS City, spatial_partition(4409832.57, 2810613.91, 500000)
)
GROUP BY spatial_partition;

SELECT 'Riyadh' as city, (5195870.62 - -20037508.34) / 500000::integer as x, (2810613.91 - -20037508.34) / 500000::integer as y;

