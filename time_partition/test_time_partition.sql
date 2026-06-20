-- =====================================================
-- BASIC TEST CASES
-- =====================================================

-- Test exception cases

-- Test 0 interval. Should raise exception
SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '0 minutes');

-- Test 20 seconds interval (interval shorter than 1 minute). Should raise exception
SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '20 seconds');

-- Test 25 hours interval (interval longer than 24 hours). Should raise exception
SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '25 hours');

-- Test invalid hour interval. Should raise exception
SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '7 hours');

-- Test invalid 90-minute period which is not a valid hour interval (1.5 hours). Should raise exception
SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '90 minutes', INTERVAL '0 minutes');

-- Test valid 120-minute (2 hours) period. Should not raise exception
SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '120 minutes');

-- Invalid interval shift tests
SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '15 minutes', INTERVAL '15 minutes');

-- Test interval shift greater than period. Should raise exception
SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '15 minutes', INTERVAL '20 minutes');

-- Basic functionality tests
SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '15 minutes');

SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '30 minutes');

SELECT hsql_time_partition(TIMESTAMP '2026-06-18 00:40:00', INTERVAL '1 hour');

SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '4 hour');

-- Edge cases
SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '15 minutes');

SELECT hsql_time_partition(TIMESTAMP '2025-01-01 23:59:59', INTERVAL '15 minutes');

SELECT hsql_time_partition(TIMESTAMP '2025-01-01 23:30:00', INTERVAL '12 hours');

-- Test shift cases
SELECT hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '15 minutes', INTERVAL '0 minutes') AS shift_0,
    hsql_time_partition(TIMESTAMP '2025-01-01 00:00:00', INTERVAL '15 minutes', INTERVAL '10 minutes') AS shift_10;

