-- Active: 1757744206257@@127.0.0.1@5432@hadathdb

-- Drop existing objects if they exist
DROP FUNCTION IF EXISTS temporal_partition CASCADE;
DROP FUNCTION IF EXISTS time_partition CASCADE;
DROP TYPE IF EXISTS temporal_partition_id CASCADE;
DROP TYPE IF EXISTS time_partition_id CASCADE;

-- Create a custom type for the time partition key
CREATE TYPE time_partition_id AS (
    start_timestamp TIMESTAMP,
    end_timestamp TIMESTAMP
);

-- Create a function to get time partition key (returns time_partition_id)
CREATE OR REPLACE FUNCTION time_partition(
    input_timestamp TIMESTAMP,
    interval_length INTERVAL,
    shift_interval INTERVAL DEFAULT INTERVAL '0'
) RETURNS time_partition_id AS $$
DECLARE
    partition_start TIMESTAMP;
    partition_end TIMESTAMP;
    midnight TIMESTAMP;
    seconds_since_midnight NUMERIC;
    interval_total_seconds NUMERIC;
    interval_number INTEGER;
    total_minutes NUMERIC;
    hours NUMERIC;
BEGIN
    -- Validate interval length (must be between 1 minute and 24 hours)
    IF interval_length < INTERVAL '1 minute' OR interval_length > INTERVAL '24 hours' THEN
        RAISE EXCEPTION 'Interval must be between 1 minute and 24 hours';
    END IF;

    IF interval_length < INTERVAL '60 minutes' THEN
    -- Validate interval is an allowed minute interval
        IF interval_length NOT IN (INTERVAL '1 minute', INTERVAL '2 minutes', INTERVAL '3 minutes', INTERVAL '4 minutes', INTERVAL '5 minutes', INTERVAL '6 minutes', INTERVAL '10 minutes', INTERVAL '12 minutes', INTERVAL '15 minutes', INTERVAL '20 minutes', INTERVAL '30 minutes', INTERVAL '60 minutes') THEN
            RAISE EXCEPTION 'Invalid minute interval. Must be one of: 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, 60';
        END IF;
    ELSE
        -- Validate interval is an allowed hour interval 
        IF interval_length NOT IN (INTERVAL '1 hour', INTERVAL '2 hours', INTERVAL '3 hours', INTERVAL '4 hours', INTERVAL '6 hours', INTERVAL '8 hours', INTERVAL '12 hours', INTERVAL '24 hours') THEN
            RAISE EXCEPTION 'Invalid hour interval. Must be one of: 1, 2, 3, 4, 6, 8, 12, 24';
        END IF;
    END IF;

    -- Validate shift interval
    IF shift_interval >= interval_length THEN
        RAISE EXCEPTION 'Shift interval must be less than interval length';
    END IF;
    
    -- Calculate the start of the interval
    interval_total_seconds := EXTRACT(EPOCH FROM interval_length);
    midnight := DATE_TRUNC('day', input_timestamp) + shift_interval;
    
    seconds_since_midnight := EXTRACT(EPOCH FROM (input_timestamp - midnight));
    interval_number := FLOOR(seconds_since_midnight / interval_total_seconds);
    partition_start := midnight + (interval_number * interval_length);
    partition_end := partition_start + interval_length;
    
    -- Return the interval representing the partition interval
    RETURN (partition_start, partition_end);
END;
$$ LANGUAGE plpgsql IMMUTABLE;
