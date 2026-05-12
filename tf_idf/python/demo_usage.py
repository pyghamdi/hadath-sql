import argparse
import os
import sys

import psycopg2
from psycopg2.extras import RealDictCursor
from psycopg2 import sql

# This directory contains tf_idf.py
_script_dir = os.path.dirname(os.path.abspath(__file__))
if _script_dir not in sys.path:
    sys.path.insert(0, _script_dir)

from tf_idf import TFIDF
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
            # hsql_process_text returns rows of (term, freq).
            # Expand them into a plain token list expected by TFIDF's tokenizer contract.
            cursor.execute(
                "SELECT * FROM hsql_process_text(%s)",
                (text,)
            )
            result = cursor.fetchall()
            tokens: List[str] = []
            for term, freq in result:
                if term and freq:
                    tokens.extend([term] * int(freq))
            return tokens
    
    return tokenize


def create_tfidf_model(connection, table_name: str, text_column: str):
    """
    Create a TF-IDF model from a PostgreSQL table.
    
    The model is created by processing the documents in the table and building a TF-IDF model. The model using PostgreSQL's to_tsvector function to tokenize the text.

    Args:
        connection: PostgreSQL database connection
        table_name: Name of the PostgreSQL table containing text content
        text_column: Name of the column containing document text
        
    Returns:
        A TFIDF object
    """
    print("=== Creating TF-IDF Model ===\n")
    
    try:
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
            return
        
        print(f"Found {len(rows)} documents\n")
        
        # Process documents using the model
        print("Processing documents...")
        document_count = 0
        for row in rows:
            text = row[text_column]
            if text:  # Only process non-empty text
                tfidf.insert(text)
                document_count += 1
                print(f"Processed: {document_count} of {len(rows)} documents")
        
        return tfidf
        
    except psycopg2.Error as e:
        print(f"PostgreSQL error while building model: {e}")
    except Exception as e:
        print(f"Error retrieving documents: {e}")


def demo_usage(
    table_name: str,
    text_column: str,
    host: str,
    port: str,
    database: str,
    user: str,
    password: str,
):
    """
    Demonstrate TF-IDF model creation and usage.
    Connection handling is centralized here.
    """
    connection = None
    try:
        print(f"Connecting to PostgreSQL database '{database}'...")
        connection = psycopg2.connect(
            host=host,
            port=port,
            database=database,
            user=user,
            password=password,
        )
        tfidf_model = create_tfidf_model(
            connection=connection,
            table_name=table_name,
            text_column=text_column,
        )
        if tfidf_model is not None:
            print(tfidf_model.get_tfidf_vector("Machine learning algorithms are fascinating and have revolutionized many industries. They can identify patterns in large datasets that would be impossible for humans to detect manually in reasonable time."))
        return tfidf_model
    finally:
        if connection is not None:
            connection.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Build a TF-IDF model from a PostgreSQL table (hsql_process_text tokenizer)."
    )
    parser.add_argument("--table-name", required=True)
    parser.add_argument("--text-column", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True)
    parser.add_argument("--database", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--password", required=True)
    args = parser.parse_args()
    demo_usage(
        table_name=args.table_name,
        text_column=args.text_column,
        host=args.host,
        port=args.port,
        database=args.database,
        user=args.user,
        password=args.password,
    )
