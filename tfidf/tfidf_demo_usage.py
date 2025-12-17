import sys
import os
import psycopg2
from psycopg2.extras import RealDictCursor
from psycopg2 import sql

# Add parent directory to path to allow importing tfidf module
current_dir = os.path.dirname(os.path.abspath(__file__))
parent_dir = os.path.dirname(current_dir)
if parent_dir not in sys.path:
    sys.path.insert(0, parent_dir)

from tfidf import TFIDF
from typing import List


def create_to_tsvector_tokenizer(db_connection):
    """
    Create a tokenizer function that uses PostgreSQL's to_tsvector function.
    
    Args:
        db_connection: PostgreSQL database connection
        
    Returns:
        A function that takes text and returns a list of tokens
    """
    def tokenize(text: str) -> List[str]:
        """
        Tokenize text using PostgreSQL's to_tsvector function.
        
        Args:
            text: The text to tokenize
            
        Returns:
            List of tokenized terms
        """
        if not text:
            return []
        
        with db_connection.cursor() as cursor:
            # Use to_tsvector to get tokens, then convert to array
            # This matches the approach in tfidf.sql: tsvector_to_array(to_tsvector('english', document_text))
            cursor.execute(
                "SELECT tsvector_to_array(to_tsvector('english', %s))",
                (text,)
            )
            result = cursor.fetchone()
            if result and result[0]:
                # PostgreSQL array is automatically converted to Python list by psycopg2
                return list(result[0])
            return []
    
    return tokenize


def demo_usage(table_name: str, 
               text_column: str = 'text',
               host: str = '127.0.0.1',
               port: str = '5432',
               database: str = 'hadathdb',
               user: str = 'postgres',
               password: str = 'postgres'):
    """
    Demonstrate the usage of the TFIDF class by retrieving documents from PostgreSQL.
    
    Args:
        table_name: Name of the PostgreSQL table containing text content
        text_column: Name of the column containing document text (default: 'text')
        host: PostgreSQL host (default: '127.0.0.1')
        port: PostgreSQL port (default: '5432')
        database: Database name (default: 'hadathdb')
        user: Database user (default: 'postgres')
        password: Database password (default: 'postgres')
    """
    print("=== TF-IDF Model Demo ===\n")
    
    # Connect to PostgreSQL
    try:
        print(f"Connecting to PostgreSQL database '{database}'...")
        connection = psycopg2.connect(
            host=host,
            port=port,
            database=database,
            user=user,
            password=password
        )
        
        # Create tokenizer function using to_tsvector
        tokenizer = create_to_tsvector_tokenizer(connection)
        
        # Initialize TFIDF with the tokenizer
        tfidf = TFIDF(tokenizer=tokenizer)
        
        # Query documents from the specified table (using safe identifier quoting)
        query = sql.SQL("""
            SELECT {}
            FROM {}
        """).format(
            sql.Identifier(text_column),
            sql.Identifier(table_name),
        )
        
        print(f"Retrieving documents from table '{table_name}'...")
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(query)
            rows = cursor.fetchall()
        
        if not rows:
            print(f"Warning: No documents found in table '{table_name}'")
            connection.close()
            return
        
        print(f"Found {len(rows)} documents\n")
        
        # Process documents using the model
        print("Processing documents...")
        for row in rows:
            text = row[text_column]
            if text:  # Only process non-empty text
                tfidf.process_document(text)
                print(f"Processed: {text[:80]}{'...' if len(text) > 80 else ''}")
        
        text = 'The quick brown fox jumps over the lazy dog'
        # print(f"TF-IDF weight vector for '{text}': {tfidf.get_tfidf_weight_vector(text)}")
        tfidf.print_stats()
        tfidf.print_document_frequency()
        tfidf_vector = tfidf.get_tfidf_weight_vector(text)
        print(f"TF-IDF weight vector for '{text}': {tfidf_vector}")
        for term, weight in tfidf_vector.items():
            print(f"Term: {term}, Weight: {weight}")
        
        connection.close()
        
    except psycopg2.Error as e:
        print(f"Error connecting to PostgreSQL: {e}")
        return
    except Exception as e:
        print(f"Error retrieving documents: {e}")
        return
    
    print(f"\nModel statistics: {tfidf.get_stats()}")

if __name__ == "__main__":
    # Example usage: retrieve documents from PostgreSQL table
    # Modify the table name and connection parameters as needed
    demo_usage(table_name='sample_documents', text_column='content')

