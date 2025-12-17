from collections import defaultdict
from typing import List, Dict, Union, Optional, Any, Callable
import re
import math
from collections import Counter


class TFIDF:
    """
    TF-IDF (Term Frequency-Inverse Document Frequency) Class

    This class is used to represent a collection of documents as TF-IDF weight vectors.
    The TF-IDF weight for a term in a document is the product of TF and IDF:
    TF-IDF(t, d) = TF(t, d) * IDF(t)

    The class maintains document frequency statistics (how many documents contain each term)
    and can compute TF, IDF, and TF-IDF scores for any text and term combination.

    **Key Features:**
    - Incremental document processing: Add documents one at a time
    - Flexible tokenization: Uses a provided tokenizer function (e.g., PostgreSQL's to_tsvector)
    - On-the-fly computation: TF-IDF scores are computed dynamically from document text
    - No document storage: Only maintains aggregate statistics, not individual documents

    **Attributes:**
        number_of_documents_containing_term (defaultdict[int]): Maps each term to the number
            of documents that contain it (document frequency, df(t))
        total_documents (int): Total number of documents processed
        tokenizer (Callable[[str], List[str]]): The tokenizer function used to tokenize text
    """

    def __init__(self, tokenizer: Callable[[str], List[str]]):
        """
        Initialize the TF-IDF model.

        Args:
            tokenizer: A function that takes a text string and returns a list of terms.
                      Example: A function that uses PostgreSQL's to_tsvector.

        Raises:
            ValueError: If tokenizer is None or not callable

        Note:
            The tokenizer function must be provided at initialization and should take a string
            as input and return a list of term strings. The same tokenizer is used consistently
            throughout the model's lifetime to ensure consistent tokenization.
        """
        if tokenizer is None:
            raise ValueError(
                "tokenizer is required. TFIDF requires a tokenizer function."
            )
        if not callable(tokenizer):
            raise ValueError(
                "tokenizer must be a callable function that takes a string and returns List[str]."
            )

        self.number_of_documents_containing_term = defaultdict(int)
        # Total number of documents processed
        self.total_documents = 0
        # Tokenizer function for text tokenization
        self.tokenizer = tokenizer

    def tokenize(self, text: str) -> List[str]:
        """
        Tokenize text using the provided tokenizer function.

        Args:
            text: The text to tokenize

        Returns:
            List of tokenized terms
        """
        if not text:
            return []

        # Use the provided tokenizer function
        return self.tokenizer(text)

    def process_document(self, text: str) -> None:
        """
        Process a document by tokenizing it and updating document frequency statistics.

        This method:
        1. Increments the total document count
        2. Tokenizes the document using the provided tokenizer
        3. Updates the document frequency for each term in the document

        Args:
            text: The text content of the document to process
        """
        self.total_documents += 1

        terms = self.tokenize(text)
        self.add_terms(terms)

    def add_terms(self, terms: List[str]) -> None:
        """
        Add terms to the document frequency dictionary.

        For each unique term in the list, increments the count of documents containing that term.
        This method is typically called internally by process_document() after tokenization.
        Note: Each term is counted only once per document, regardless of how many times it appears.

        Args:
            terms: A list of term strings to add to the document frequency dictionary
        """
        # Use set to get unique terms - each term should only increment document frequency once per document
        for term in set(terms):
            self.number_of_documents_containing_term[term] += 1

    def get_idf(self, term: str) -> float:
        """
        Return the IDF (inverse document frequency) value for a given term.

        IDF measures how rare or common a term is across the entire document collection.
        It is calculated as: IDF(t) = log(total_documents / documents_containing_term)

        Args:
            term: The term to compute IDF for

        Returns:
            The IDF value for the term as a float. Returns 0.0 if:
            - No documents have been processed (total_documents == 0)
            - The term has not been seen in any document
        """
        if (
            self.total_documents == 0
            or term not in self.number_of_documents_containing_term
        ):
            return 0.0

        # IDF = log(total_documents / documents_containing_term)
        return math.log(
            (self.total_documents / self.number_of_documents_containing_term[term]),
            math.e,
        )

    def get_tf(self, text: str, term: str) -> float:
        """
        Return the TF (term frequency) value for a given term in a document.

        TF measures how frequently a term appears in a specific document.
        It is calculated as the count of occurrences of the term in the document.

        Args:
            text: The text content of the document to analyze
            term: The term to compute TF for

        Returns:
            The TF value (count of term occurrences) as a float. Returns 0.0 if the term
            does not appear in the text.
        """
        # Count the number of times a term appears in a document
        terms = self.tokenize(text)
        return terms.count(term)

    def get_tfidf(self, text: str, term: str) -> float:
        """
        Return the TF-IDF score for a given term in a document.

        TF-IDF is the product of Term Frequency (TF) and Inverse Document Frequency (IDF):
        TF-IDF(t, d) = TF(t, d) * IDF(t)

        This score reflects how important a term is to a specific document relative to
        the entire collection. Terms that appear frequently in a document but rarely in
        the collection will have high TF-IDF scores.

        Args:
            text: The text content of the document to analyze
            term: The term to compute TF-IDF for

        Returns:
            The TF-IDF score as a float. Returns 0.0 if:
            - The term does not appear in the text (TF = 0)
            - The term has not been seen in any processed document (IDF = 0)
        """
        tf = self.get_tf(text, term)
        idf = self.get_idf(term)
        return tf * idf

    def get_tfidf_weight_vector(self, text: str) -> Dict[str, float]:
        """
        Return the TF-IDF weight vector for a document.

        Args:
            text: The text to compute the TF-IDF weight vector for

        Returns:
            Dictionary mapping terms to their TF-IDF weight
        """
        vector = {}
        for term in self.tokenize(text):
            vector[term] = self.get_tfidf(text, term)
        return vector

    def get_stats(self) -> Dict[str, int]:
        """
        Return statistics about the current collection.

        Returns:
            Dictionary with collection statistics:
            - total_documents: Total number of documents
            - total_unique_tokens: Total number of unique tokens
        """
        return {
            "total_documents": self.total_documents,
            "total_unique_tokens": len(self.number_of_documents_containing_term),
        }

    def print_stats(self) -> None:
        """
        Print the statistics about the current collection.
        """
        print(f"Total documents: {self.total_documents}")
        print(f"Total unique tokens: {len(self.number_of_documents_containing_term)}")
        for term, count in self.number_of_documents_containing_term.items():
            print(f"Term: {term}, Count: {count}")

    def print_document_frequency(self) -> None:
        """
        Print the document frequency statistics.
        """
        for term, count in self.number_of_documents_containing_term.items():
            print(f"Term: {term}, Count: {count}")
