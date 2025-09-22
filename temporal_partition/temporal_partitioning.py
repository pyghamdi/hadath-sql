from datetime import datetime, timedelta
from typing import Optional, Tuple
import psycopg2
from psycopg2.extensions import connection

# Valid interval constants
VALID_MINUTE_INTERVALS = {1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, 60}
VALID_HOUR_INTERVALS = {1, 2, 3, 4, 6, 8, 12, 24}

def get_temporal_partition(
    timestamp: datetime,
    interval_length: timedelta,
    shift_interval: Optional[timedelta] = None,
) -> Tuple[datetime, datetime]:
    """
    Get the time partition key for a timestamp.

    Partitions time into fixed-length, non-overlapping periods.

    Valid period lengths:
    - Minutes: 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, 60
    - Hours: 1, 2, 3, 4, 6, 8, 12, 24

    Each partition is a closed-open interval [iΔt + shift, (i+1)Δt + shift),
    where i is a non-negative integer, Δt is the period length, and shift is optional.

    Args:
        timestamp: The timestamp to partition
        interval_length: Length of each time period
        shift_interval: Optional time shift to apply to each partition

    Returns:
        Tuple of (interval_start, interval_end) representing the time interval

    Raises:
        ValueError: If interval_length is invalid or shift_interval >= interval_length
    """
    # Validate interval length (must be between 1 minute and 24 hours)
    if interval_length < timedelta(minutes=1) or interval_length > timedelta(hours=24):
        raise ValueError("Interval length must be between 1 minute and 24 hours")
    
    # Validate interval is an allowed minute interval
    if interval_length < timedelta(minutes=60):
        interval_minutes = int(interval_length.total_seconds() / 60)
        if interval_minutes not in VALID_MINUTE_INTERVALS:
            raise ValueError(
                f"Invalid minute interval. Must be one of: {sorted(VALID_MINUTE_INTERVALS)}"
            )
    else:
        # Validate interval is an allowed hour interval
        interval_hours = int(interval_length.total_seconds() / 3600)
        if interval_hours not in VALID_HOUR_INTERVALS:
            raise ValueError(
                f"Invalid hour interval. Must be one of: {sorted(VALID_HOUR_INTERVALS)}"
            )
    
    # Validate shift_interval
    if shift_interval is not None and shift_interval >= interval_length:
        raise ValueError("shift interval must be less than interval length")
    
    # Calculate the start of the interval
    interval_total_seconds = int(interval_length.total_seconds())
    midnight = timestamp.replace(hour=0, minute=0, second=0, microsecond=0)
    if shift_interval is not None:
        midnight = midnight + shift_interval
    
    seconds_since_midnight = (timestamp - midnight).total_seconds()
    interval_number = int(seconds_since_midnight // interval_total_seconds)
    interval_start = midnight + timedelta(seconds=interval_number * interval_total_seconds)
    interval_end = interval_start + interval_length
    
    return (interval_start, interval_end)

def print_partition(partition: Tuple[datetime, datetime]):
    print(partition[0].strftime("%Y-%m-%d %H:%M:%S"), partition[1].strftime("%Y-%m-%d %H:%M:%S"))
