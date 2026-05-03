-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- trigram similarity for BM25-style text search

-- Documents table
-- tsvector column enables PostgreSQL full-text search (BM25 scoring via ts_rank)
CREATE TABLE IF NOT EXISTS documents (
    id          BIGSERIAL PRIMARY KEY,
    content     TEXT        NOT NULL,
    embedding   VECTOR(384),                          -- all-MiniLM-L6-v2 dims
    fts         TSVECTOR GENERATED ALWAYS AS            -- auto-updated FTS column
                    (to_tsvector('english', content)) STORED,
    source      TEXT,
    doc_type    TEXT,
    chunk_index INTEGER,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- HNSW index for fast approximate nearest-neighbour (better than IVFFlat for
-- iterative inserts -- no need to set lists, handles growing collections well)
CREATE INDEX IF NOT EXISTS documents_hnsw_idx
    ON documents
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- GIN index on the FTS column for fast full-text search
CREATE INDEX IF NOT EXISTS documents_fts_idx
    ON documents
    USING gin (fts);

-- Index on source for metadata-filtered queries
CREATE INDEX IF NOT EXISTS documents_source_idx
    ON documents (source);
