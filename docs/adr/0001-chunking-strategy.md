# 1. Chunking strategy

Date: 2026-06-23

## Status

Accepted

## Context

Documents must be split into smaller pieces ("chunks") before embedding, because
embedding models have a bounded context window and because retrieval quality is
best when each chunk is a single coherent unit of meaning. The split has to
balance several forces:

- **Embedding/context limits.** Chunks must comfortably fit the embedding
  model's input and leave room for a chunk to be pasted into a chat prompt at
  query time.
- **Retrieval granularity.** Chunks that are too large dilute the embedding
  (many topics averaged into one vector); chunks that are too small lose the
  surrounding context needed to be useful.
- **Boundary loss.** A fact that straddles a chunk boundary can become
  unretrievable if neither chunk contains enough of it.
- **Idempotent re-ingestion.** Re-ingesting an unchanged (or lightly edited)
  document must not needlessly re-embed every chunk — embeddings cost money and
  time. This requires a *stable, deterministic* chunk identity.

The thin slice used a crude char-budget splitter (~1500 chars, no overlap) with
a `chars / 4` token estimate. That was enough to prove the pipeline but is
inaccurate (the real tokenizer disagrees with chars/4) and cuts mid-sentence.

## Decision

`Chunker` (`app/services/chunker.rb`) produces overlapping, token-budgeted,
structure-aware chunks:

- **Token counting** uses `tiktoken_ruby` with the `cl100k_base` encoding — the
  same tokenizer family OpenAI's embedding models use — instead of a chars/4
  heuristic. Counts are therefore accurate, not approximate.
- **Budget.** Target **~600 tokens** per chunk with a hard ceiling of **800
  tokens**. This sits well inside the embedding model's window and keeps each
  chunk a digestible unit.
- **Structure awareness.** Text is split along the strongest available boundary
  first: paragraphs (blank-line separated), then sentences, then — only as a
  last resort for a budget-busting whitespace-free blob — a hard split of the
  token stream into max-token windows. A markdown heading starts a new chunk so
  a section's heading travels with its body.
- **Overlap.** Consecutive chunks share **~12.5%** of trailing tokens (whole
  sentences) so a fact spanning a boundary remains retrievable from at least one
  chunk.
- **Stable identity.** Each chunk carries a `content_hash` = SHA-256 of its
  (overlap-inclusive) content. Chunking is fully deterministic, so identical
  input always yields identical hashes. `DocumentIngestor` reconciles chunks by
  `content_hash`: unchanged chunks keep their row and their existing embedding,
  new chunks are inserted, removed chunks are deleted, and only new/changed
  chunks are embedded. See [0002-vector-index](0002-vector-index.md) for how the
  resulting embeddings are stored and searched.

## Consequences

- Re-ingesting an unchanged document embeds nothing; editing a document
  re-embeds only the chunks that actually changed.
- Token counts stored on chunks are exact, which makes downstream prompt-budget
  accounting reliable.
- The chunker is coupled to the `cl100k_base` tokenizer. If we move to an
  embedding model with a materially different tokenizer, the budget constants
  (and possibly the encoding) must be revisited.
- Overlap means adjacent chunks duplicate some text, modestly increasing storage
  and embedding cost in exchange for better boundary recall. The overlap ratio
  is a tunable knob (`Chunker::OVERLAP_RATIO`).
- Because `content_hash` includes the overlap, editing one chunk can change the
  hash of the *following* chunk (its overlap prefix shifts). This is acceptable:
  the reconciler simply re-embeds that neighbour.
