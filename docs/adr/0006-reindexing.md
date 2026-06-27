# 6. Re-indexing & embedding-model migration

Date: 2026-06-26

## Status

Accepted

## Context

The embedding model is not forever. A better model ships, a price changes, or the
provider deprecates one — and when it changes, **existing vectors become invalid**:
a query embedded with model B is not comparable to chunk vectors produced by model
A, so a mixed corpus silently returns garbage rankings (RAG_ASSISTANT_ARCHITECTURE.md
§10). We need a way to move the corpus to a new model without (a) a blind wipe that
deletes all retrieval until everything is re-embedded, and (b) ever comparing
vectors across models.

Two facts in the existing design make this tractable:

- Every chunk records the **`embedding_model`** (and `embedding_dim`) that produced
  its vector (§4). So we can tell, per row, what's stale.
- The **Retriever filters every search to `LlmClient.config.embedding_model`**
  (`retriever.rb`). So at query time we only ever match vectors from one model —
  cross-model contamination is already impossible, and the configured model value
  is effectively a switch for "which model's vectors are live."

The forces:

- Re-embedding the whole corpus is slow and costs real API calls; it must be
  **batched, idempotent, and resumable** (a rate limit or crash mid-run must not
  force a restart from zero — the same property `DocumentIngestor` already has).
- We want to **validate** the new vectors (on the eval harness, §9) *before* user
  traffic depends on them.
- A model with a **different output dimension** doesn't just need re-embedding — it
  needs a `vector(N)` column + HNSW index migration. Writing a 3072-dim vector into
  a `vector(1536)` column is a hard error, and must be one (no silent corruption).

## Options considered

1. **Blind destroy-and-re-embed.** Drop all embeddings, re-embed. Simple, but
   retrieval is dead for the entire (possibly long) backfill. Rejected.
2. **True "alongside" dual-model storage** — a second vector column (or shadow
   chunk rows) holding the new model's vectors next to the old, so the old keeps
   serving until cutover with *zero* degradation. This is the textbook
   zero-downtime rolling re-index. It needs a schema migration per migration and
   doubles vector storage during the transition. Powerful, but heavier than a
   single-node portfolio target warrants — recorded here as the production-grade
   extension. Deferred.
3. **In-place batched backfill, gated by the configured model.** Re-embed stale
   chunks in place, batched/idempotent/resumable; keep the *old* model configured
   (so the Retriever keeps serving the not-yet-migrated chunks) until the backfill
   completes and the eval harness validates the new model, then flip the config.
   Chosen.

## Decision

Provide a **`Reindexer` service** and a **`reindex` rake task** (§12):

- `Reindexer#status` → chunk counts grouped by `embedding_model` (watch progress).
- `Reindexer#backfill` → re-embeds, in batches, only chunks **not already at**
  `target_model` (including never-embedded chunks), stamping each with the new
  `embedding_model`/`embedding_dim` as its vector returns. Idempotent (a completed
  re-run is a no-op) and resumable (each chunk saved as embedded).
- `reindex:status` / `reindex:backfill[TARGET_MODEL]` expose both from the CLI.

**Cutover** is changing `LLM_EMBEDDING_MODEL` (the Retriever's filter). The intended
flow: backfill the new model → `rake eval` to confirm recall/MRR hold → flip the
configured model. For a **same-dimension** model swap this needs no migration; for a
**dimension change**, `Reindexer` raises `DimensionMismatchError` rather than writing
a mis-sized vector — that case requires a `vector(N)` column + HNSW index migration
first, performed deliberately as a separate step (option 2 territory).

## Consequences

- **No destructive wipe; idempotent & resumable.** A failed backfill is safe to
  re-run, and only un-migrated chunks are re-embedded.
- **Eval-validated cutover.** Because the configured model is the switch, we can
  validate the new vectors offline and flip atomically from the reader's side.
- **In-place means a transient mixed-model window.** While a backfill runs, the
  corpus holds both models; since the Retriever serves only the *configured* one,
  keep the old model configured until backfill completes (run it as a maintenance
  pass on a single node). True zero-degradation overlap is option 2, deliberately
  deferred — and named so the limitation is honest rather than hidden.
- **Dimension changes fail loudly.** A model that changes the vector width can't be
  backfilled in place; the guard turns that into a clear error pointing at the
  required migration instead of corrupting the column.
- **Offline-testable.** `Reindexer` runs against the Fake (deterministic vectors),
  so the idempotent/resumable backfill and the per-model `status` counts are covered
  by the deterministic suite.
