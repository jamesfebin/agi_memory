-- Required extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS age;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS cube;

-- Load AGE extension explicitly
LOAD 'age';
SET search_path = ag_catalog, public;

-- Create the graph
SELECT create_graph('memory_graph');
SELECT create_vlabel('memory_graph', 'MemoryNode');

-- Switch to public schema for our tables
SET search_path = public, ag_catalog, "$user";

-- Enums for memory types and status (same as yours)
CREATE TYPE memory_type AS ENUM ('episodic', 'semantic', 'procedural', 'strategic');
CREATE TYPE memory_status AS ENUM ('active', 'archived', 'invalidated');

-- Working Memory (temporary table or in-memory structure)
-- Could be a simple table or even a temporary table depending on usage
CREATE TABLE working_memory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    content TEXT NOT NULL,
    embedding vector(1536) NOT NULL, -- OpenAI embedding
    expiry TIMESTAMPTZ  -- Optional: Auto-expire after a set time
);

CREATE OR REPLACE FUNCTION age_in_days(created_at TIMESTAMPTZ) 
RETURNS FLOAT
IMMUTABLE
AS $$
BEGIN
    RETURN extract(epoch from (now() - created_at))/86400.0;
END;
$$ LANGUAGE plpgsql;

-- Base memory table with vector embeddings (enhanced with decay and relevance)
CREATE TABLE memories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    type memory_type NOT NULL,
    status memory_status DEFAULT 'active',
    content TEXT NOT NULL,
    embedding vector(1536) NOT NULL,
    importance FLOAT DEFAULT 0.0,
    access_count INTEGER DEFAULT 0,
    last_accessed TIMESTAMPTZ,
    decay_rate FLOAT DEFAULT 0.01,  -- Rate at which importance decays
    relevance_score FLOAT GENERATED ALWAYS AS (
        importance * exp(-decay_rate * age_in_days(created_at))
    ) STORED);

-- Episodic memories (enhanced with temporal context)
CREATE TABLE episodic_memories (
    memory_id UUID PRIMARY KEY REFERENCES memories(id),
    action_taken JSONB,
    context JSONB,
    result JSONB,
    emotional_valence FLOAT,
    verification_status BOOLEAN,
    event_time TIMESTAMPTZ,  -- When the event occurred
    CONSTRAINT valid_emotion CHECK (emotional_valence >= -1 AND emotional_valence <= 1)
);

-- Semantic memories (enhanced with semantic relations)
CREATE TABLE semantic_memories (
    memory_id UUID PRIMARY KEY REFERENCES memories(id),
    confidence FLOAT NOT NULL,
    last_validated TIMESTAMPTZ,
    source_references JSONB,
    contradictions JSONB,
    category TEXT[],
    related_concepts TEXT[],  -- Links to other semantic memories or concepts
    CONSTRAINT valid_confidence CHECK (confidence >= 0 AND confidence <= 1)
);

-- Procedural memories (same as yours)
CREATE TABLE procedural_memories (
    memory_id UUID PRIMARY KEY REFERENCES memories(id),
    steps JSONB NOT NULL,
    prerequisites JSONB,
    success_count INTEGER DEFAULT 0,
    total_attempts INTEGER DEFAULT 0,
    success_rate FLOAT GENERATED ALWAYS AS (
        CASE WHEN total_attempts > 0 
        THEN success_count::FLOAT / total_attempts::FLOAT 
        ELSE 0 END
    ) STORED,
    average_duration INTERVAL,
    failure_points JSONB
);

-- Strategic memories (same as yours)
CREATE TABLE strategic_memories (
    memory_id UUID PRIMARY KEY REFERENCES memories(id),
    pattern_description TEXT NOT NULL,
    supporting_evidence JSONB,
    confidence_score FLOAT,
    success_metrics JSONB,
    adaptation_history JSONB,
    context_applicability JSONB,
    CONSTRAINT valid_confidence CHECK (confidence_score >= 0 AND confidence_score <= 1)
);

-- Indexes for performance (same as yours, with potential addition for working memory)
CREATE INDEX ON memories USING ivfflat (embedding vector_cosine_ops);
CREATE INDEX ON memories (type);
CREATE INDEX ON memories (status);
CREATE INDEX ON memories (importance);
CREATE INDEX ON memories USING GIN (content gin_trgm_ops);

-- Temporal tracking (same as yours)
CREATE TABLE memory_changes (
    change_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    memory_id UUID REFERENCES memories(id),
    changed_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    change_type TEXT NOT NULL,
    old_value JSONB,
    new_value JSONB
);

-- Functions for memory management

-- Function to update memory timestamp (same as yours)
CREATE OR REPLACE FUNCTION update_memory_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Function to update memory importance based on access (enhanced with forgetting)
CREATE OR REPLACE FUNCTION update_memory_importance()
RETURNS TRIGGER AS $$
BEGIN
    NEW.importance = NEW.importance * (1.0 + (ln(NEW.access_count + 1) * 0.1));
    NEW.last_accessed = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Function to create memory relationship in graph (same as yours)
CREATE OR REPLACE FUNCTION create_memory_relationship(
    from_id UUID,
    to_id UUID,
    relationship_type TEXT,
    properties JSONB DEFAULT '{}'
) RETURNS VOID AS $func$
BEGIN
    PERFORM * FROM cypher('memory_graph', $cypher$
        MATCH (a:MemoryNode {memory_id: $1}), (b:MemoryNode {memory_id: $2})
        CREATE (a)-[r:$3]->(b)
        SET r = $4
    $cypher$, 
        ARRAY[from_id::text, to_id::text, relationship_type, properties::text]
    ) as (result agtype);
END;
$func$ LANGUAGE plpgsql;

-- Triggers (same as yours)
CREATE TRIGGER update_memory_timestamp
    BEFORE UPDATE ON memories
    FOR EACH ROW
    EXECUTE FUNCTION update_memory_timestamp();

CREATE TRIGGER update_importance_on_access
    BEFORE UPDATE ON memories
    FOR EACH ROW
    WHEN (NEW.access_count != OLD.access_count)
    EXECUTE FUNCTION update_memory_importance();

-- Views for memory analysis (enhanced)

CREATE VIEW memory_health AS
SELECT 
    type,
    count(*) as total_memories,
    avg(importance) as avg_importance,
    avg(access_count) as avg_access_count,
    count(*) FILTER (WHERE last_accessed > CURRENT_TIMESTAMP - INTERVAL '1 day') as accessed_last_day,
    avg(relevance_score) as avg_relevance  -- Add relevance score
FROM memories
GROUP BY type;

CREATE VIEW procedural_effectiveness AS
SELECT 
    m.content,
    p.success_rate,
    p.total_attempts,
    m.importance,
    m.relevance_score  -- Add relevance score
FROM memories m
JOIN procedural_memories p ON m.id = p.memory_id
WHERE m.status = 'active'
ORDER BY 
    p.success_rate DESC,
    m.importance DESC;

-- Scheduled tasks (conceptual, not SQL)

-- 1. Consolidation: 
--    Move data from working_memory to long-term memory based on criteria (e.g., frequency, importance).
--    This could be a function or script executed periodically.

-- 2. Forgetting/Pruning:
--    Reduce the importance of memories that haven't been accessed recently or have low relevance.
--    Archive or delete memories that fall below a certain threshold of importance or relevance.

-- 3. Optimization:
--    Re-index tables, optimize graph database for faster queries.
--    This can be done using PostgreSQL's maintenance tools (e.g., VACUUM, ANALYZE).