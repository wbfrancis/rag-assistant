# 7. Hybrid search (dense ⊕ lexical, RRF fusion)

Date: 2026-06-27

## Status

Accepted

## Context

Retrieval (ADR 0003) is a single dense leg: embed the query, cosine-kNN over
pgvector, abstain below a relevance floor. Dense retrieval is strong on meaning
but has a known blind spot — **exact lexical tokens**. Names, error codes, SKUs,
acronyms and other rare identifiers carry little semantic signal, so an embedding
can smear them together with their surroundings and rank the wrong record first.
The canonical production answer is **hybrid search**: run a lexical retriever
alongside the dense one and fuse the results, so a query is served by whichever
signal is decisive.

This is also the one feature the Phase 4 eval harness (recall@k / MRR, ADR 0005)
can *quantitatively* prove, which is why it was chosen as the headline stretch
feature over the alternatives (fallback model, org-tenancy).

Forces:

- **No new infrastructure.** Adding Elasticsearch/OpenSearch for BM25 would dwarf
  the rest of the stack. Postgres already ships full-text search (`tsvector` /
  `tsquery` / GIN), which is more than enough at this scale.
- **Two scores on different scales.** Cosine similarity (≈ -1..1) and `ts_rank`
  (unbounded, corpus-dependent) are not comparable; naively adding or
  weighting them needs tuning and drifts as the corpus changes.
- **Isolation must not drift.** Retrieval is a security boundary (ADR 0003); a
  *second* query path is a second chance to leak across tenants.
- **The abstention contract must survive.** ADR 0003 guarantees the system
  declines on out-of-domain queries. Fusion must not quietly answer a query the
  dense floor would have refused.

## Options considered

1. **Weighted sum / normalize-then-add** of cosine and `ts_rank`. Requires
   choosing (and re-tuning) weights and a normalization scheme as the corpus
   grows. Rejected — tuning burden, brittle.
2. **Reciprocal Rank Fusion (RRF).** Fuse by *rank*, not score:
   `score(chunk) = Σ 1 / (RRF_K + rank_in_list)` over the lists the chunk appears
   in. Needs no weights and no normalization because it never looks at the raw
   scores — only positions. Standard, robust, parameter-light. **Chosen.**
3. **A dedicated search engine (Elasticsearch).** Best-in-class lexical, but new
   infrastructure for a single-node portfolio target. Rejected (see ADR 0006's
   "deferred, production-grade" stance).

## Decision

Retrieval becomes two legs fused by RRF, behind the same `Retriever#call` seam —
everything downstream (abstention, `AnswerGenerator`, logging) is unchanged.

- **Generated `tsvector` column.** A `content_tsv` column on `chunks`,
  `GENERATED ALWAYS AS (to_tsvector('english', content)) STORED`, with a GIN
  index. Postgres derives it on every write, so it can never drift out of sync
  with `content` — the same "derive, don't store" stance as ADR 0001/0006. (The
  Rails schema dumper represents it natively as `t.virtual … type: :tsvector …
  stored: true`, so no `structure.sql` switch was needed.)
- **Lexical leg = OR-of-lexemes, ranked by `ts_rank`.** We deliberately rewrite
  `plainto_tsquery`'s AND into an OR. `plainto_tsquery('english', q)` ANDs every
  lexeme, so one query word absent from a chunk rejects an otherwise strong match
  (we measured "What is the SKU for the gateway **hardware**?" failing to match
  "…gateway SKU is HX-9000" purely on the stray word "hardware"). Rewriting `' &
  '` → `' | '` on plainto's already-normalized, already-quoted output (so
  hyphenated tokens like `e-4421` stay valid) gives match-on-any-term recall, and
  `ts_rank` then rewards the chunks matching *more* terms.
- **Both legs reuse the identical scoping chain.** `for_tenant` →
  `embedding_model` → non-null embedding. Tenant isolation is therefore one SQL
  predicate shared by both paths and cannot drift; a dedicated regression test
  asserts the lexical leg never returns another tenant's chunk.
- **RRF fusion, `RRF_K = 60`** (the original Cormack et al. value), as a named
  constant beside `RELEVANCE_FLOOR`. Each leg fetches a wider candidate pool
  (`DEFAULT_CANDIDATE_K = 20`) than the final `k`, so a chunk one leg ranks low
  can still win the fused top-`k`. Ties break on `id` for fully deterministic
  output (the eval harness depends on it).
- **Abstention keys off the dense leg, unchanged.** The relevance floor still
  reads the dense top cosine similarity; if the nearest neighbour is below the
  floor we abstain, *even if* the lexical leg matched. RRF may reorder which
  chunk is first, but the decision to answer at all remains a semantic one, so
  ADR 0003's guarantee is preserved verbatim. `top_similarity` is always recorded
  from the dense leg. (Consequence: a query whose only matches are lexical and
  semantically distant still abstains — the right call for a grounded assistant.)
- **Per-chunk floor only in dense mode.** Dense-only retrieval still drops
  individual sub-floor chunks (ADR 0003). Hybrid does *not* floor-filter the
  fused list — a lexically-strong, cosine-weak chunk is exactly what hybrid exists
  to surface.
- **Toggleable, default on.** `Retriever.new(hybrid:)` (and `HYBRID=` for the
  eval task) so the harness can run dense-vs-hybrid head to head and the README
  table is reproducible. `GenerateAnswerJob` uses the default (on).

## Consequences

- **Measured lift, no regression (ADR 0005 harness, text-embedding-3-small,
  k=8).** On a deliberately adversarial "buried identifier" subset — a rare code
  mentioned once inside a long ops-manual section, out-ranked under dense by a
  short, on-topic page that doesn't contain the code — hybrid lifts **MRR 0.83 →
  1.00**; overall **MRR 0.95 → 1.00** with **recall@8 = 1.00** unchanged and
  abstention identical. The result is reproducible run-to-run.
- **An honest scope note.** The textbook "dense can't match exact tokens" failure
  *barely reproduces* on short, clean records with a strong modern embedding model
  — we tried, and dense matched bare codes/SKUs at rank 1. Hybrid's value here is
  concentrated in the *dilution* case (and grows with corpus size and weaker/older
  embeddings). It is a robustness floor, not a universal recall multiplier — and
  it never does worse than dense.
- **No new infrastructure, no tuning.** One generated column + one GIN index +
  one extra query + ~10 lines of RRF. No weights to maintain.
- **Isolation stays a single shared predicate** across both legs; the second
  retrieval path did not become a second leak path.
- **A small honesty cost in `scored`.** A lexical-only chunk has no comparable
  cosine score, so its `similarity` is `nil` in the result (and in
  `retrieval_scores`). Downstream consumers already treat `scored` as an ordered
  list, so this is cosmetic.
