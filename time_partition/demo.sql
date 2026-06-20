-- =====================================================
-- Usage Examples
-- =====================================================

SELECT hsql_time_partition(TIMESTAMP '2025-01-01 01:10:00', INTERVAL '30 minutes') AS partition_30min,
    hsql_time_partition(TIMESTAMP '2025-01-01 01:10:00', INTERVAL '1 hour') AS partition_1hour,
    hsql_time_partition(TIMESTAMP '2025-01-01 01:10:00', INTERVAL '3 hour') AS partition_3hour;

    -- Example: Group rows by temporal partition and count per interval
    SELECT
        hsql_time_partition(ts, INTERVAL '30 minutes') AS partition,
        COUNT(*) AS event_count
    FROM
        (VALUES
            (TIMESTAMP '2025-01-01 00:05:00'),   -- Group 1 (00:00-00:30)
            (TIMESTAMP '2025-01-01 00:15:00'),   -- Group 1 (00:00-00:30)
            (TIMESTAMP '2025-01-01 00:35:00'),   -- Group 2 (00:30-01:00)
            (TIMESTAMP '2025-01-01 00:50:00'),   -- Group 2 (00:30-01:00)
            (TIMESTAMP '2025-01-01 01:10:00'),   -- Group 3 (01:00-01:30)
            (TIMESTAMP '2025-01-01 01:29:00')    -- Group 3 (01:00-01:30)
        ) AS docs(ts)
    GROUP BY
        partition
    ORDER BY
        partition;