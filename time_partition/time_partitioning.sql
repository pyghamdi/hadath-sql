-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- Temporal partitioning (time_partitioning.sql)
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- Divides each day into fixed-length intervals and maps a timestamp to the
-- interval that contains it. The interval is returned as a partition identifier
-- that can be used directly in GROUP BY.
--
-- Defines:
--   time_partition_id                             type: start and end of an interval
--   hsql_time_partition(input_timestamp, interval_length [, shift_interval])
--
-- Parameters of hsql_time_partition:
--   input_timestamp  timestamp to assign to an interval
--   interval_length  length of the intervals. Allowed values:
--                      minutes: 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, 60
--                      hours:   1, 2, 3, 4, 6, 8, 12, 24
--                    These are the lengths that divide a day evenly.
--   shift_interval   optional shift of the interval boundaries (default 0). It
--                    can be positive or negative and must be shorter than
--                    interval_length.
--
-- Returns: time_partition_id (start_timestamp, end_timestamp). The interval
--   includes its start and excludes its end.
--
-- Examples:
--   -- Returns ("2025-01-01 01:00:00","2025-01-01 01:30:00")
--   SELECT hsql_time_partition(TIMESTAMP '2025-01-01 01:10:00', INTERVAL '30 minutes');
--
--   -- Number of documents in each 30-minute interval
--   SELECT hsql_time_partition(ts, INTERVAL '30 minutes') AS period, COUNT(*)
--   FROM docs
--   GROUP BY period;
--
--   -- The same intervals moved forward by 15 minutes (00:15-00:45, 00:45-01:15, ...)
--   SELECT hsql_time_partition(ts, INTERVAL '30 minutes', INTERVAL '15 minutes') AS period, COUNT(*)
--   FROM docs
--   GROUP BY period;
--
-- Notes:
--   - Without a shift, the intervals of a day start at midnight.
--   - Invalid arguments (a length that is not in the list above, or a shift that
--     is not shorter than the length) raise an error.
--   - More examples are in demo.sql in this directory.

-- Identifier of a time interval: its start and end timestamps.
CREATE TYPE time_partition_id AS (
    start_timestamp TIMESTAMP,
    end_timestamp TIMESTAMP
);


-- Raises the error for invalid arguments of hsql_time_partition; called only
-- when the check in hsql_time_partition fails, so it only has to work out which
-- rule was broken. It is declared IMMUTABLE so that constant invalid arguments
-- are reported once, while the query is planned.
CREATE OR REPLACE FUNCTION hsql_invalid_time_partition_args(
    interval_length INTERVAL,
    shift_interval INTERVAL
) RETURNS time_partition_id AS $$
BEGIN
    IF interval_length IS NULL THEN
        RAISE EXCEPTION 'Interval length must not be NULL';
    END IF;

    -- The interval length must be between 1 minute and 24 hours
    IF interval_length < INTERVAL '1 minute' OR interval_length > INTERVAL '24 hours' THEN
        RAISE EXCEPTION 'Interval must be between 1 minute and 24 hours';
    END IF;

    IF interval_length < INTERVAL '60 minutes' THEN
        IF interval_length NOT IN (INTERVAL '1 minute', INTERVAL '2 minutes', INTERVAL '3 minutes', INTERVAL '4 minutes', INTERVAL '5 minutes', INTERVAL '6 minutes', INTERVAL '10 minutes', INTERVAL '12 minutes', INTERVAL '15 minutes', INTERVAL '20 minutes', INTERVAL '30 minutes') THEN
            RAISE EXCEPTION 'Invalid minute interval. Must be one of: 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, 60';
        END IF;
    ELSIF interval_length NOT IN (INTERVAL '1 hour', INTERVAL '2 hours', INTERVAL '3 hours', INTERVAL '4 hours', INTERVAL '6 hours', INTERVAL '8 hours', INTERVAL '12 hours', INTERVAL '24 hours') THEN
        RAISE EXCEPTION 'Invalid hour interval. Must be one of: 1, 2, 3, 4, 6, 8, 12, 24';
    END IF;

    -- Otherwise the shift is the problem
    RAISE EXCEPTION 'Shift interval magnitude must be less than interval length';
END;
$$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

-- The function is a single SQL expression so that PostgreSQL can inline it into
-- the calling query. When interval_length and shift_interval are constants, as in
-- hsql_time_partition(ts, INTERVAL '30 minutes'), the planner evaluates the
-- argument check once and the query computes only the interval arithmetic per row.
-- Inlining stops if the function becomes STRICT, gets a SET clause, or its body
-- is no longer a single expression; keep that in mind when editing it.
CREATE OR REPLACE FUNCTION hsql_time_partition(
    input_timestamp TIMESTAMP,
    interval_length INTERVAL,
    shift_interval INTERVAL DEFAULT INTERVAL '0'
) RETURNS time_partition_id AS $$
    SELECT CASE
        -- The interval length must be one of the allowed minute or hour values, and
        -- the shift (forward or backward) must be shorter than the interval length.
        WHEN interval_length IN (
                 INTERVAL '1 minute', INTERVAL '2 minutes', INTERVAL '3 minutes', INTERVAL '4 minutes',
                 INTERVAL '5 minutes', INTERVAL '6 minutes', INTERVAL '10 minutes', INTERVAL '12 minutes',
                 INTERVAL '15 minutes', INTERVAL '20 minutes', INTERVAL '30 minutes', INTERVAL '60 minutes',
                 INTERVAL '2 hours', INTERVAL '3 hours', INTERVAL '4 hours', INTERVAL '6 hours',
                 INTERVAL '8 hours', INTERVAL '12 hours', INTERVAL '24 hours')
             AND COALESCE(shift_interval, INTERVAL '0') > -interval_length
             AND COALESCE(shift_interval, INTERVAL '0') < interval_length
        THEN
            -- The day's grid starts at midnight plus the shift; the partition starts
            -- a whole number of interval lengths after it.
            ROW(
                (DATE_TRUNC('day', input_timestamp) + COALESCE(shift_interval, INTERVAL '0'))
                    + FLOOR(EXTRACT(EPOCH FROM (input_timestamp - (DATE_TRUNC('day', input_timestamp) + COALESCE(shift_interval, INTERVAL '0'))))
                            / EXTRACT(EPOCH FROM interval_length))::integer * interval_length,
                (DATE_TRUNC('day', input_timestamp) + COALESCE(shift_interval, INTERVAL '0'))
                    + (FLOOR(EXTRACT(EPOCH FROM (input_timestamp - (DATE_TRUNC('day', input_timestamp) + COALESCE(shift_interval, INTERVAL '0'))))
                             / EXTRACT(EPOCH FROM interval_length))::integer + 1) * interval_length
            )::time_partition_id
        ELSE hsql_invalid_time_partition_args(interval_length, shift_interval)
    END
$$ LANGUAGE sql IMMUTABLE PARALLEL SAFE;
