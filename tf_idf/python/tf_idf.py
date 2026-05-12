import math
from collections import Counter, defaultdict
from typing import Any, Callable, Dict, List, Union


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
        document_frequency (defaultdict[int]): Maps each term to the number
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

        self.document_frequency = defaultdict(int)
        # Total number of documents processed
        self.total_documents = 0
        # Tokenizer function for text tokenization
        self.tokenizer = tokenizer

    def tokenize(
        self, text: str, output: str = "dict"
    ) -> Union[Dict[str, int], List[tuple[str, int]]]:
        """
        Tokenize text using the provided tokenizer function.

        Args:
            text: The text to tokenize
            output: Output format for term counts.
                - "dict": returns {term: count}
                - "list": returns [(term, count), ...]

        Returns:
            Term counts as either a dictionary or list of (term, count) pairs.
        """
        if not text:
            return {} if output == "dict" else []

        terms = self.tokenizer(text)
        if isinstance(terms, dict):
            term_counts = {str(term): int(count) for term, count in terms.items()}
        elif (
            isinstance(terms, list)
            and terms
            and isinstance(terms[0], tuple)
            and len(terms[0]) == 2
        ):
            term_counts = {str(term): int(count) for term, count in terms}
        else:
            term_counts = dict(Counter(terms))

        if output == "dict":
            return term_counts
        if output == "list":
            return list(term_counts.items())

        raise ValueError("output must be either 'dict' or 'list'.")

    def insert(self, text: str) -> None:
        """
        Insert a document into the TF-IDF model.

        This method inserts a document into the TF-IDF model by:
        1. Tokenizes the document using the provided tokenizer
        2. Adds the terms to the document frequency dictionary

        Args:
            text: The text content of the document to insert
        """
        self.total_documents += 1
        terms = self.tokenize(text, output="dict")
        for term in terms:
            self.document_frequency[term] += 1

    def get_df(self, term: str) -> int:
        """
        Return the document frequency for a given term.
        """
        if self.total_documents == 0 or term not in self.document_frequency:
            return 0
        return self.document_frequency[term]

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
        if self.get_df(term) == 0:
            return 0.0
        return math.log(self.total_documents / self.get_df(term), 10)

    def get_tf(self, text: str, term: str) -> float:
        """
        Return the TF (term frequency) value for a given term in a document.

        TF is the share of token mass in the document: occurrences of `term` divided by
        the total number of tokens (with multiplicity), matching `hsql_create_tf_idf_tbl`
        in tf_idf.sql.

        Args:
            text: The text content of the document to analyze
            term: The term to compute TF for

        Returns:
            TF as a float in [0, 1]. Returns 0.0 if the term does not appear in the text
            or the document has no tokens.
        """
        # TF = term count / total token count in document (matches PostgreSQL hsql_create_tf_idf_tbl).
        terms = self.tokenize(text, output="dict")
        total_tokens = float(sum(terms.values()))
        if total_tokens == 0.0:
            return 0.0
        return float(terms.get(term, 0)) / total_tokens

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

    def get_tfidf_vector(self, text: str) -> Dict[str, float]:
        """
        Return the TF-IDF vector for a text.

        The TF-IDF vector is a dictionary mapping terms to their TF-IDF scores.

        Args:
            text: The text to compute the TF-IDF vector for
        """
        terms = self.tokenize(text, output="list")
        return {term: self.get_tfidf(text, term) for term, _ in terms}

    def get_stats(self) -> Dict[str, Any]:
        """
        Return statistics about the current collection.

        Returns:
            Dictionary with collection statistics:
            - total_documents: Total number of documents
            - document_frequency: Dictionary mapping terms to the number of documents that contain them
        """
        return {
            "total_documents": self.total_documents,
            "document_frequency": self.document_frequency,
        }

    def print_document_frequency_stats(self) -> None:
        """
        Print the statistics about the current collection.
        """
        print(f"Total documents: {self.total_documents}")
        print(f"Total unique tokens: {len(self.document_frequency)}")
