# 3. Retrieval

Date: 2026-06-24

## Status

Accepted

## Context

Phase 2 builds the online query side's first half: retrieval. Given a tenant and
a natural-language query, the system must return the most relevant chunks from
*that tenant's* corpus, ranked, so Phase 3 can feed them to an answer generator.
Constraints and forces (RAG_ASSISTANT_ARCHITECTURE.md §4, §5, §10):

- Vectors live in Postgres via pgvector, behind an **HNSW** index built with
  `vector_cosine_ops` (ADR 0002). Queries must use cosine distance to match it.
- The corpus is multi-tenant and isolation is a **security** property, not a
  quality nicety: a query must never see another tenant's chunks.
- Embeddings are model-specific. A query embedded with one model is not
  comparable to chunks embedded with another, so retrieval must compare like
  with like — including across a future rolling re-index where two models'
  vectors temporarily coexist.
- A retriever that always returns its top-k hands weak, off-topic context to the
  LLM on out-of-domain questions, inviting hallucination. The system should be
  able to **abstain**.

## Decision

Add a `Retriever` service (`app/services/retriever.rb`) that embeds the query
through the same `LlmClient.embed` call used at ingestion and runs a single
tenant-scoped nearest-neighbour query:

```ruby
Chunk.for_tenant(tenant)
     .where(embedding_model: LlmClient.config.embedding_model)
     .where.not(embedding: nil)
     .nearest_neighbors(:embedding, query_vector, distance: "cosine")
     .limit(k)
```

- **Tenant pre-filter, composed in one query.** `for_tenant` chains first, so
  tenant isolation and the kNN search become a single SQL statement. This is cheap
  because `tenant_id` is denormalized onto `chunks` (§4 / ADR 0002). We never
  filter by a tenant id taken from params — the tenant is the authenticated
  `Current.user`. *Caveat:* combining a `WHERE` filter with an HNSW search can
  in principle starve the index (it walks the graph, then discards out-of-filter
  rows), hurting recall for tenants that are a tiny slice of a huge table. At
  current scale this is a non-issue; if it bites, the lever is a partial/scoped
  index or raising `ef_search`. Recorded here so the trade-off is not rediscovered
  from scratch.
- **`embedding_model` scoping.** Results are restricted to the active embedding
  model so mixed-model vectors can't pollute ranking during a rolling re-index.
- **Cosine distance → similarity.** `neighbor` returns a `neighbor_distance`;
  similarity is its complement, `1.0 - distance`.
- **Relevance floor `0.30`, configurable.** If the best hit's similarity is below
  the floor, the Retriever **abstains** (empty result, `abstained? == true`)
  rather than returning weak context (§5, §10). `0.30` suits
  `text-embedding-3-small`, where genuinely relevant chunks commonly score
  ~0.3–0.5 and a higher floor would abstain on nearly everything. The value is a
  single constant (`Retriever::RELEVANCE_FLOOR`) overridable per call via
  `min_similarity:`, so the Phase 4 eval harness can sweep it against
  recall@k / MRR.
- **Single-query only.** A blank query short-circuits to an empty, non-abstaining
  result with no embedding call. Multi-turn query contextualization (rewriting a
  follow-up against conversation history) is deferred to Phase 3.

A minimal `SearchController` + view (`/search`) lets a reviewer eyeball ranked
results and the abstain path; it reads the tenant from `Current.user` only.

## Consequences

- Retrieval and tenant isolation are the same query, so isolation can't be
  forgotten at a call site; a request-level and a service-level regression test
  assert a tenant can never retrieve another's chunks.
- Abstention moves the "no relevant context" decision to retrieval time, where it
  is a deterministic threshold, instead of trusting the LLM to decline.
- The floor and `k` are the two knobs Phase 4 will tune; both are parameters, so
  tuning needs no code change to the Retriever.
- The `embedding_model` filter assumes chunks are stamped with the model that
  produced them (they are, via `DocumentIngestor#embed_missing`). A re-index must
  re-stamp as it re-embeds for those chunks to become visible to the new model.
- HNSW remains approximate (ADR 0002): ranking is high-recall, not exact. Fine
  for retrieval; the eval harness will quantify it.
```
