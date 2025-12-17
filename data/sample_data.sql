-- #########################################################
-- Create a sample documents table
-- #########################################################
CREATE TABLE IF NOT EXISTS sample_documents (
    document_id SERIAL PRIMARY KEY,
    content TEXT,
    created_at TIMESTAMP DEFAULT NULL
);

/* #########################################################
remove rows from sample_documents table
######################################################### */
DELETE FROM sample_documents;

-- Insert sample data for testing
INSERT INTO sample_documents (content, created_at) VALUES
    ('The quick brown fox jumps over the lazy dog', '2025-01-01 12:00:00'),
    ('A quick brown fox runs in the forest', '2025-01-01 12:30:00'),
    ('The lazy dog sleeps in the sun', '2025-01-01 13:00:00'),
    ('Machine learning algorithms are fascinating', '2025-01-01 13:30:00'),
    ('The fox and the dog are both animals', '2025-01-01 14:00:00');