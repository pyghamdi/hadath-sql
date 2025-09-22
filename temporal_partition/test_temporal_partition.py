"""
Test file for temporal_partition PostgreSQL function.

To run the tests:
1. Install required packages: pip install pytest psycopg2-binary
2. Create the temporal_partition function in your database first (run temporal_partitioning.sql)
3. Run tests: pytest test_temporal_partition.py -v

Database connection uses these defaults:
- host: 127.0.0.1
- port: 5432  
- database: hadathdb
- user: postgres
- password: (empty)
"""

import pytest
import psycopg2
from psycopg2.extras import RealDictCursor
from datetime import datetime, timedelta
from typing import Any


class PostgreSQLTestSetup:
    """Helper class for PostgreSQL test setup and connection management."""
    
    def __init__(self):
        # Database connection parameters
        self.db_config = {
            'host': '127.0.0.1',
            'port': '5432',
            'database': 'hadathdb',
            'user': 'postgres',
            'password': 'postgres'
        }
        self.connection = None
    
    def connect(self):
        """Establish connection to PostgreSQL database."""
        try:
            self.connection = psycopg2.connect(**self.db_config)
            print(f"Connected to PostgreSQL: {self.connection}")
            return self.connection
        except psycopg2.Error as e:
            pytest.skip(f"Could not connect to PostgreSQL: {e}")
    
    def disconnect(self):
        """Close database connection."""
        if self.connection:
            self.connection.close()
    
    
    def execute_query(self, query: str, params: tuple = None) -> Any:
        """Execute a query and return the result."""
        if not self.connection:
            self.connect()
        
        with self.connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(query, params)
            if cursor.description:  # If there are results
                return cursor.fetchall()
            return None


@pytest.fixture(scope="session")
def db_setup():
    """Session-scoped fixture for database setup."""
    setup = PostgreSQLTestSetup()
    
    # Connect to database
    setup.connect()
    
    # Note: Make sure the temporal_partition function is already created in the database
    
    yield setup
    
    # Cleanup
    setup.disconnect()


@pytest.fixture(scope="function")
def db_connection(db_setup):
    """Function-scoped fixture for database connection."""
    return db_setup


class TestTemporalPartition:
    """Test class for the temporal_partition PostgreSQL function."""
    
    def to_string(self, timestamp: datetime):
        return timestamp.strftime("%Y-%m-%d %H:%M:%S")
    
    def to_datetime(self, timestamp: str):
        return datetime.strptime(timestamp, "%Y-%m-%d %H:%M:%S")
    
    def check_result_partition(self, expected_partition: tuple[str, str], result_partition: dict):
        expected_start_timestamp, expected_end_timestamp = expected_partition
        
        if self.to_string(result_partition['start_timestamp']) == expected_start_timestamp and self.to_string(result_partition['end_timestamp']) == expected_end_timestamp:
            return True
        else:
            return False

    def test_basic_15_minute(self, db_connection):
        """
        Test basic functionality of temporal_partition function with 15-minute intervals.
        
        This test verifies that:
        1. The function exists and can be called
        2. It returns the expected partition boundaries
        3. The returned values match the expected format (temporal_partition_id type)
        """
        # Test timestamp: 2025-01-01 14:30:00
        test_timestamp = '2025-01-01 00:00:00'
        interval_length = '15 minutes'
        
        # Query the temporal_partition function
        query = """
        SELECT * FROM temporal_partition(%s::timestamp, %s::interval);
        """
        
        result = db_connection.execute_query(query, (test_timestamp, interval_length))
        
        # Verify we got a result
        assert result is not None
        
        # result is a list of dictionaries
        assert len(result) == 1 # should be only one row
        
        # Extract the result values
        partition= result[0] # should be only one row and should be a dictionary
        assert partition is not None
        start_timestamp, end_timestamp = partition['start_timestamp'], partition['end_timestamp']

        expected_partition = ('2025-01-01 00:00:00', '2025-01-01 00:15:00')
        assert self.check_result_partition(expected_partition, partition) is True
        
        # Verify the interval length is correct (15 minutes)
        interval_duration = end_timestamp - start_timestamp
        assert interval_duration == timedelta(minutes=15)
        
        # Verify the test timestamp falls within the partition
        test_dt = self.to_datetime(test_timestamp)
        assert start_timestamp <= test_dt < end_timestamp

    def test_basic_15_minute_shift_10_minutes(self, db_connection):
        """
        Test basic functionality of temporal_partition function with 15-minute intervals and a 15-minute shift.
        """
        test_timestamp = '2025-01-01 00:00:00'
        interval_length = '15 minutes'
        shift_interval = '10 minutes'
        
        expected_partition = ('2024-12-31 23:55:00', '2025-01-01 00:10:00')
        query = """
        SELECT * FROM temporal_partition(%s::timestamp, %s::interval, %s::interval);
        """
        
        result = db_connection.execute_query(query, (test_timestamp, interval_length, shift_interval))
        
        assert result is not None
        assert len(result) == 1
        
        partition = result[0]
        assert partition is not None
        assert self.check_result_partition(expected_partition, partition) is True
        
        interval_duration = partition['end_timestamp'] - partition['start_timestamp']
        assert interval_duration == timedelta(minutes=15)
        
        test_dt = self.to_datetime(test_timestamp)
        assert partition['start_timestamp'] <= test_dt < partition['end_timestamp']

if __name__ == "__main__":
    # You can run this file directly for debugging
    pytest.main([__file__, "-v"])
