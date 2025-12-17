import math
from collections import defaultdict, Counter
from typing import Dict, List, Set, Tuple, Optional
import re


class IncrementalTFIDF:
    """
    A class for computing TF-IDF (Term Frequency-Inverse Document Frequency) incrementally
    and computing cosine similarity between documents.
    """
    
    def __init__(self):
        # Document frequency: how many documents contain each term
        self.doc_frequency = defaultdict(int)
        # Total number of documents processed
        self.total_documents = 0
        # Document vocabulary (terms in each document)
        self.document_terms = {}  # doc_id -> set of terms
        # Document term counts (TF for each document)
        self.document_term_counts = {}  # doc_id -> Counter(terms)
        # Clustering structures
        self.clusters = {}  # cluster_id -> {'documents': set, 'centroid': dict}
        self.document_cluster = {}  # doc_id -> cluster_id
        self.next_cluster_id = 0
        
    def compute_cosine_similarity(self, doc_id1: str, doc_id2: str) -> float:
        """
        Compute the cosine similarity between two documents using TF-IDF vectors.
        
        Args:
            doc_id1: Identifier of the first document
            doc_id2: Identifier of the second document
            
        Returns:
            Cosine similarity score between 0 and 1
        """
        # Get TF-IDF vectors for both documents
        vector1 = self.get_document_vector(doc_id1)
        vector2 = self.get_document_vector(doc_id2)
        
        if not vector1 or not vector2:
            return 0.0
        
        # Get all unique terms from both documents
        all_terms = set(vector1.keys()) | set(vector2.keys())
        
        # Compute dot product
        dot_product = 0.0
        norm1 = 0.0
        norm2 = 0.0
        
        for term in all_terms:
            tfidf1 = vector1.get(term, 0.0)
            tfidf2 = vector2.get(term, 0.0)
            
            dot_product += tfidf1 * tfidf2
            norm1 += tfidf1 * tfidf1
            norm2 += tfidf2 * tfidf2
        
        # Avoid division by zero
        if norm1 == 0.0 or norm2 == 0.0:
            return 0.0
        
        # Cosine similarity = dot_product / (norm1 * norm2)
        return dot_product / (math.sqrt(norm1) * math.sqrt(norm2))
    
    def get_most_similar_documents(self, doc_id: str, top_k: int = 5) -> List[Tuple[str, float]]:
        """
        Find the most similar documents to a given document.
        
        Args:
            doc_id: The document to find similar documents for
            top_k: Number of most similar documents to return
            
        Returns:
            List of tuples (document_id, similarity_score) sorted by similarity
        """
        similarities = []
        
        for other_doc_id in self.document_terms.keys():
            if other_doc_id != doc_id:
                similarity = self.compute_cosine_similarity(doc_id, other_doc_id)
                similarities.append((other_doc_id, similarity))
        
        # Sort by similarity score (descending)
        similarities.sort(key=lambda x: x[1], reverse=True)
        
        return similarities[:top_k]
    
    
    
    def compute_cluster_centroid(self, cluster_id: str) -> Dict[str, float]:
        """
        Compute the centroid of a cluster by averaging TF-IDF vectors of all documents in the cluster.
        
        Args:
            cluster_id: The cluster identifier
            
        Returns:
            Dictionary representing the cluster centroid (averaged TF-IDF vector)
        """
        if cluster_id not in self.clusters:
            return {}
        
        cluster = self.clusters[cluster_id]
        documents = cluster['documents']
        
        if not documents:
            return {}
        
        # Get all unique terms across all documents in the cluster
        all_terms = set()
        for doc_id in documents:
            all_terms.update(self.document_terms.get(doc_id, []))
        
        # Compute average TF-IDF for each term
        centroid = {}
        for term in all_terms:
            total_tfidf = 0.0
            count = 0
            
            for doc_id in documents:
                if doc_id in self.document_terms and term in self.document_terms[doc_id]:
                    tfidf = self.compute_tfidf(doc_id, term)
                    total_tfidf += tfidf
                    count += 1
            
            if count > 0:
                centroid[term] = total_tfidf / count
        
        return centroid
    
    def compute_document_cluster_distance(self, doc_id: str, cluster_id: str) -> float:
        """
        Compute the distance between a document and a cluster centroid using cosine distance.
        
        Args:
            doc_id: The document identifier
            cluster_id: The cluster identifier
            
        Returns:
            Distance value (1 - cosine_similarity), where 0 means identical and 1 means orthogonal
        """
        # Get document vector
        doc_vector = self.get_document_vector(doc_id)
        if not doc_vector:
            return 1.0  # Maximum distance for empty document
        
        # Get cluster centroid
        cluster_centroid = self.compute_cluster_centroid(cluster_id)
        if not cluster_centroid:
            return 1.0  # Maximum distance for empty cluster
        
        # Get all unique terms from both vectors
        all_terms = set(doc_vector.keys()) | set(cluster_centroid.keys())
        
        # Compute cosine similarity
        dot_product = 0.0
        norm_doc = 0.0
        norm_cluster = 0.0
        
        for term in all_terms:
            doc_tfidf = doc_vector.get(term, 0.0)
            cluster_tfidf = cluster_centroid.get(term, 0.0)
            
            dot_product += doc_tfidf * cluster_tfidf
            norm_doc += doc_tfidf * doc_tfidf
            norm_cluster += cluster_tfidf * cluster_tfidf
        
        # Avoid division by zero
        if norm_doc == 0.0 or norm_cluster == 0.0:
            return 1.0
        
        # Cosine similarity = dot_product / (norm_doc * norm_cluster)
        cosine_similarity = dot_product / (math.sqrt(norm_doc) * math.sqrt(norm_cluster))
        
        # Return cosine distance (1 - cosine_similarity)
        return 1.0 - cosine_similarity
    
    def find_closest_cluster(self, doc_id: str) -> Tuple[Optional[str], float]:
        """
        Find the closest cluster to a document.
        
        Args:
            doc_id: The document identifier
            
        Returns:
            Tuple of (closest_cluster_id, distance) or (None, float('inf')) if no clusters exist
        """
        if not self.clusters:
            return None, float('inf')
        
        min_distance = float('inf')
        closest_cluster = None
        
        for cluster_id in self.clusters.keys():
            distance = self.compute_document_cluster_distance(doc_id, cluster_id)
            if distance < min_distance:
                min_distance = distance
                closest_cluster = cluster_id
        
        return closest_cluster, min_distance
    
    def update_cluster_centroid(self, cluster_id: str) -> None:
        """
        Update the centroid of a cluster.
        
        Args:
            cluster_id: The cluster identifier
        """
        if cluster_id in self.clusters:
            centroid = self.compute_cluster_centroid(cluster_id)
            self.clusters[cluster_id]['centroid'] = centroid
    
    def add_document_to_cluster(self, doc_id: str, cluster_id: str) -> None:
        """
        Add a document to a cluster and update the cluster centroid.
        
        Args:
            doc_id: The document identifier
            cluster_id: The cluster identifier
        """
        if cluster_id not in self.clusters:
            self.clusters[cluster_id] = {'documents': set(), 'centroid': {}}
        
        self.clusters[cluster_id]['documents'].add(doc_id)
        self.document_cluster[doc_id] = cluster_id
        
        # Update cluster centroid
        self.update_cluster_centroid(cluster_id)
    
    def create_new_cluster(self, doc_id: str) -> str:
        """
        Create a new cluster with the given document.
        
        Args:
            doc_id: The document identifier
            
        Returns:
            The new cluster identifier
        """
        cluster_id = f"cluster_{self.next_cluster_id}"
        self.next_cluster_id += 1
        
        self.clusters[cluster_id] = {'documents': set(), 'centroid': {}}
        self.add_document_to_cluster(doc_id, cluster_id)
        
        return cluster_id
    
    def incremental_cluster(self, documents: List[Tuple[str, str]], distance_threshold: float = 0.7) -> Dict[str, any]:
        """
        Perform incremental clustering on a list of documents.
        
        For each document, find the most similar (closest) cluster c to document d.
        If distance(d, c) is within the distance threshold, then add d to c and update c;
        otherwise, create a new cluster and add it to the cluster set.
        
        Args:
            documents: List of tuples (doc_id, text) to cluster
            distance_threshold: Maximum distance for a document to be added to an existing cluster
            
        Returns:
            Dictionary containing clustering results and statistics
        """
        clustering_results = {
            'clusters_created': 0,
            'documents_clustered': 0,
            'documents_added_to_existing': 0,
            'documents_in_new_clusters': 0,
            'cluster_assignments': {}
        }
        
        for doc_id, text in documents:
            # Add document to the TF-IDF collection
            self.add_document(doc_id, text)
            clustering_results['documents_clustered'] += 1
            
            # Find closest cluster
            closest_cluster, min_distance = self.find_closest_cluster(doc_id)
            
            if closest_cluster is not None and min_distance <= distance_threshold:
                # Add to existing cluster
                self.add_document_to_cluster(doc_id, closest_cluster)
                clustering_results['documents_added_to_existing'] += 1
                clustering_results['cluster_assignments'][doc_id] = {
                    'cluster_id': closest_cluster,
                    'distance': min_distance,
                    'action': 'added_to_existing'
                }
            else:
                # Create new cluster
                new_cluster_id = self.create_new_cluster(doc_id)
                clustering_results['clusters_created'] += 1
                clustering_results['documents_in_new_clusters'] += 1
                clustering_results['cluster_assignments'][doc_id] = {
                    'cluster_id': new_cluster_id,
                    'distance': min_distance,
                    'action': 'created_new_cluster'
                }
        
        return clustering_results
    
    def get_cluster_summary(self) -> Dict[str, any]:
        """
        Get a summary of all clusters.
        
        Returns:
            Dictionary containing cluster information
        """
        summary = {
            'total_clusters': len(self.clusters),
            'cluster_details': {}
        }
        
        for cluster_id, cluster_info in self.clusters.items():
            documents = cluster_info['documents']
            centroid = cluster_info['centroid']
            
            summary['cluster_details'][cluster_id] = {
                'document_count': len(documents),
                'documents': list(documents),
                'centroid_terms': len(centroid),
                'top_centroid_terms': sorted(centroid.items(), key=lambda x: x[1], reverse=True)[:5]
            }
        
        return summary


def demo_incremental_clustering():
    """
    Demonstrate the incremental clustering functionality.
    """
    print("\n" + "="*60)
    print("=== Incremental Clustering Demo ===")
    print("="*60 + "\n")
    
    # Create a new instance for clustering
    tfidf_cluster = IncrementalTFIDF()
    
    # Sample documents for clustering (with different topics)
    documents_to_cluster = [
        ('doc1', 'The quick brown fox jumps over the lazy dog'),
        ('doc2', 'A quick brown fox runs in the forest'),
        ('doc3', 'The lazy dog sleeps in the sun'),
        ('doc4', 'Machine learning algorithms are fascinating'),
        ('doc5', 'Deep learning neural networks process data'),
        ('doc6', 'The fox and the dog are both animals'),
        ('doc7', 'Artificial intelligence and machine learning'),
        ('doc8', 'Natural language processing with Python'),
        ('doc9', 'The brown fox is very quick'),
        ('doc10', 'Data science and analytics are important')
    ]
    
    print("Documents to cluster:")
    for doc_id, text in documents_to_cluster:
        print(f"  {doc_id}: {text}")
    
    # Perform incremental clustering with different thresholds
    thresholds = [0.5, 0.7, 0.8]
    
    for threshold in thresholds:
        print(f"\n--- Clustering with distance threshold = {threshold} ---")
        
        # Reset for new clustering
        tfidf_cluster = IncrementalTFIDF()
        
        # Perform clustering
        results = tfidf_cluster.incremental_cluster(documents_to_cluster, distance_threshold=threshold)
        
        print(f"Clustering Results:")
        print(f"  - Documents clustered: {results['documents_clustered']}")
        print(f"  - Clusters created: {results['clusters_created']}")
        print(f"  - Documents added to existing clusters: {results['documents_added_to_existing']}")
        print(f"  - Documents in new clusters: {results['documents_in_new_clusters']}")
        
        # Show cluster assignments
        print(f"\nCluster Assignments:")
        for doc_id, assignment in results['cluster_assignments'].items():
            print(f"  {doc_id}: {assignment['cluster_id']} (distance: {assignment['distance']:.4f}, action: {assignment['action']})")
        
        # Show cluster summary
        summary = tfidf_cluster.get_cluster_summary()
        print(f"\nCluster Summary:")
        print(f"  Total clusters: {summary['total_clusters']}")
        
        for cluster_id, details in summary['cluster_details'].items():
            print(f"\n  {cluster_id}:")
            print(f"    Documents: {details['documents']}")
            print(f"    Document count: {details['document_count']}")
            print(f"    Top centroid terms: {details['top_centroid_terms']}")
        
        print("-" * 50)


def demo_single_document_clustering():
    """
    Demonstrate clustering one document at a time (true incremental).
    """
    print("\n" + "="*60)
    print("=== Single Document Incremental Clustering Demo ===")
    print("="*60 + "\n")
    
    # Create a new instance
    tfidf_cluster = IncrementalTFIDF()
    
    # Documents to add one by one
    documents = [
        ('news1', 'Breaking news about technology stocks rising'),
        ('news2', 'Technology companies report strong quarterly earnings'),
        ('sports1', 'Football team wins championship game'),
        ('sports2', 'Basketball player scores winning basket'),
        ('news3', 'Stock market reaches new all-time high'),
        ('tech1', 'New smartphone features artificial intelligence'),
        ('sports3', 'Soccer match ends in dramatic penalty shootout')
    ]
    
    distance_threshold = 0.6
    
    print(f"Adding documents one by one with distance threshold = {distance_threshold}")
    print()
    
    for doc_id, text in documents:
        print(f"Adding: {doc_id} - {text}")
        
        # Add document to TF-IDF collection
        tfidf_cluster.add_document(doc_id, text)
        
        # Find closest cluster
        closest_cluster, min_distance = tfidf_cluster.find_closest_cluster(doc_id)
        
        print(f"  Closest cluster: {closest_cluster}, Distance: {min_distance:.4f}")
        
        if closest_cluster is not None and min_distance <= distance_threshold:
            # Add to existing cluster
            tfidf_cluster.add_document_to_cluster(doc_id, closest_cluster)
            print(f"  → Added to existing cluster {closest_cluster}")
        else:
            # Create new cluster
            new_cluster_id = tfidf_cluster.create_new_cluster(doc_id)
            print(f"  → Created new cluster {new_cluster_id}")
        
        # Show current cluster state
        summary = tfidf_cluster.get_cluster_summary()
        print(f"  Current clusters: {summary['total_clusters']}")
        for cluster_id, details in summary['cluster_details'].items():
            print(f"    {cluster_id}: {details['documents']}")
        print()
    
    # Final cluster summary
    print("=== Final Clustering Results ===")
    final_summary = tfidf_cluster.get_cluster_summary()
    print(f"Total clusters: {final_summary['total_clusters']}")
    
    for cluster_id, details in final_summary['cluster_details'].items():
        print(f"\n{cluster_id}:")
        print(f"  Documents: {details['documents']}")
        print(f"  Count: {details['document_count']}")
        print(f"  Top terms: {details['top_centroid_terms']}")


if __name__ == "__main__":
    demo_usage()
    # demo_incremental_clustering()
    # demo_single_document_clustering()
