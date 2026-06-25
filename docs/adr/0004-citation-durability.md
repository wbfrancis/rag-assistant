# 4. Citation durability

Date: 2026-06-24

## Status

Accepted

## Context

Phase 3 grounds each assistant answer in the chunks the Retriever surfaced and
renders **citations** linking the answer back to those source chunks. We persist
`messages.chunk_ids` (a `uuid[]`) so an answer records exactly which chunks
produced it — essential for both the UI citations and debugging "why did the model
say that?" (RAG_ASSISTANT_ARCHITECTURE.md §4).

But chunks are not stable. Ingestion is idempotent and reconciles chunks as a diff
(ADR 0001 / `DocumentIngestor`): re-ingesting a document inserts new chunks and
**deletes** removed ones, and a `Chunker` change shifts boundaries so most chunks
are replaced. Deleting a document cascades `dependent: :destroy` to its chunks.
Either way, a `chunk_id` recorded on a historical message can dangle — the row it
points at is gone. A naive citation that just loads `Chunk.find(id)` would then
500 or silently drop the citation, and the answer's provenance — the whole point —
is lost. §4 names this explicitly and requires a deliberate choice.

The forces:

- Citations must keep rendering on **old** messages even after the underlying
  corpus changes — provenance is a durability property, not a best-effort one.
- We still want a **live** link to the current document/chunk when it still exists
  (so a reader can open the source).
- The deterministic test suite must be able to assert citation rendering offline.

## Options considered

1. **Reference-only (`chunk_ids`), resolve at render time.** Simplest, but
   citations break exactly when the corpus is edited — the common case for an
   actively maintained document set. Rejected.
2. **Soft-delete chunks.** Keep deleted/replaced chunks around (e.g. a
   `discarded_at`) so citations always resolve. Keeps one source of truth, but
   leaks dead rows into the vector table (the Retriever must now exclude them
   everywhere — a new way to accidentally surface stale context), and complicates
   the idempotent diff. Heavy for the benefit. Rejected for this scope.
3. **Snapshot the citation onto the message.** At answer time, copy the minimal
   display data for each cited chunk onto the message. Citations render from the
   snapshot and survive any later change to the chunk. Chosen.

## Decision

Persist a **`messages.citations` jsonb snapshot** alongside `chunk_ids`. At
generation time `AnswerGenerator` writes, per cited chunk:

```json
{ "chunk_id": "...", "document_id": "...", "document_title": "...",
  "position": 3, "excerpt": "first 300 chars of the chunk text" }
```

The view renders citations entirely from this snapshot, so historical answers keep
their provenance verbatim even after re-ingest or document deletion. `chunk_ids`
is retained for live linking and debugging (joining back to current rows when they
still exist); `retrieval_scores` similarly records the similarity per cited chunk.

## Consequences

- **Durable provenance.** Citations on old messages never break; the excerpt and
  source title are frozen as of the answer.
- **Mild denormalization / staleness.** If a document is later retitled, the
  snapshot shows the old title. Acceptable — a citation is a record of what
  grounded the answer *then*, not a live view.
- **The document link can dangle.** We still link to `document_id`; if that
  document was deleted, the link 404s but the citation text (title + excerpt) still
  renders from the snapshot, so the provenance survives. A future enhancement could
  detect the missing document and render the excerpt without a link.
- **Offline-testable.** Rendering depends only on persisted jsonb, so the suite
  asserts citations deterministically with the Fake (see `chat_flow_spec`).

This keeps the Retriever and the idempotent ingestion diff unchanged (no
soft-delete bookkeeping) while making provenance a durable property of the answer.
