# 2. Vector storage and index

Date: 2026-06-23

## Status

Accepted

## Context

Retrieval is similarity search over chunk embeddings: given a query embedding,
find the nearest chunk embeddings. We need to decide where the vectors live and
how they are indexed. Constraints:

- We already run **PostgreSQL** as the system of record (documents, chunks,
  tenancy, auth). Introducing a second datastore purely for vectors would add
  operational surface, a second consistency boundary, and cross-store joins to
  re-attach a vector hit to its tenant-scoped chunk row.
- Embeddings come from `text-embedding-3-small`, which produces **1536-dimension**
  vectors normalized for **cosine** similarity.
- The corpus is multi-tenant; every similarity search must stay inside one
  tenant's rows (see the `TenantScoped` concern and the denormalized `tenant_id`
  on `chunks`).

## Decision

Store embeddings in Postgres using the **pgvector** extension, accessed through
the **`neighbor`** gem.

- The `chunks.embedding` column is `vector(1536)`, matching the embedding model's
  dimensionality. The dimension and model name are also stored per-chunk
  (`embedding_dim`, `embedding_model`) so a future model migration can be done
  incrementally and audited.
- The column is **nullable**: `DocumentIngestor` persists a chunk *before* it has
  an embedding and fills the vector in afterwards, which is what makes embedding
  resumable (a retry re-embeds only chunks still missing a vector). See
  [0001-chunking-strategy](0001-chunking-strategy.md).
- An **HNSW** index (`opclass: :vector_cosine_ops`) backs approximate
  nearest-neighbour search:

  ```
  index ["embedding"], using: :hnsw, opclass: :vector_cosine_ops
  ```

  HNSW gives fast, high-recall approximate search with good query latency, at the
  cost of slower index builds and more memory than IVFFlat. For an
  interactive RAG assistant, query latency and recall matter more than ingest-time
  index cost, so HNSW is the right trade-off. Cosine distance matches how the
  embedding model was trained.
- Searches are issued through `neighbor`'s `nearest_neighbors` on the
  tenant-scoped `Chunk` relation, so vector search and tenant isolation compose
  in a single SQL query — no second datastore, no cross-store join.

## Consequences

- One datastore: vectors are transactionally consistent with the chunk rows that
  own them, and every similarity query is naturally tenant-scoped by chaining off
  `for_tenant`.
- HNSW is approximate: results are high-recall but not guaranteed exact. This is
  acceptable for retrieval ranking. Index parameters (`m`, `ef_construction`,
  and query-time `ef_search`) are tunable if recall/latency needs change.
- The index is tied to 1536-dim cosine vectors. Changing the embedding model's
  dimensionality or distance metric requires a new column/index and a backfill;
  the per-chunk `embedding_model`/`embedding_dim` columns exist to make that
  migration tractable.
- pgvector must be installed and the `vector` extension enabled in every
  environment (it is, via the schema's `enable_extension "vector"`).
