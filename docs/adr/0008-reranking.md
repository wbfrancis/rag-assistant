# 8. LLM re-ranking (optional second stage)

Date: 2026-06-27

## Status

Accepted

## Context

Hybrid retrieval (ADR 0007) is a cheap, high-recall *first* stage: it gets the
right chunk into the candidate pool, but its ordering is approximate — RRF fuses
two rankings by position without ever judging a full passage against the query.
The textbook next step is a **two-stage pipeline**: retrieve a wide pool cheaply,
then *re-rank* the top ~20 with a stronger, costlier model so the single best
chunk lands at rank 1, lifting MRR and the quality of the context the answer is
grounded in.

We already have a strong model behind `LlmClient` and no cross-encoder infra, so
the natural re-ranker is the LLM itself: show it the query and the candidates and
ask for an ordering.

Forces:

- **Online cost & latency.** Re-rank adds a chat call to every query — the
  opposite of the offline, cacheable ingestion path.
- **Non-determinism.** An LLM ordering is not reproducible, which is in tension
  with the deterministic, CI-gated eval harness (ADR 0005).
- **It must never make things worse** than the hybrid order it reorders.

## Options considered

1. **A hosted cross-encoder re-ranker** (e.g. Cohere Rerank, a BGE model). Higher
   quality per the literature, but new infrastructure / a second vendor for a
   single-node portfolio target. Deferred (same stance as ADR 0006/0007).
2. **Fold re-rank into `Retriever`.** Rejected: it would put an online, paid,
   non-deterministic model call inside the otherwise pure dense+lexical SQL
   service, breaking its single responsibility and its deterministic tests.
3. **A separate `Reranker` the caller opts into.** Chosen. The `Retriever` stays
   deterministic; re-rank is an answer-side concern wrapped around its result by
   `GenerateAnswerJob` (and by the eval harness when measuring).

## Decision

Add `app/services/reranker.rb`, a thin wrapper over a `Retriever::Result`.

- **One LLM call, compact JSON ordering.** It sends the query + the numbered
  candidate snippets and asks for *only* a JSON array of indices, most-relevant
  first. Parsing a list of integers is cheap and hard to get wrong; the prompt
  tells the model to prefer a passage that actually contains the specific
  identifier/value asked about over one that merely describes the topic.
- **Never worse than the fused order.** On any parse failure, empty/invalid
  output, an abstained result, or ≤1 candidate, it returns the hybrid order
  untouched (and skips the model call entirely in the trivial cases). Indices the
  model omits are appended in their original order, so a model that drops
  candidates never loses recall. Transient LLM errors are *not* swallowed — they
  propagate to the job's existing retry/backoff.
- **Toggleable, default OFF** (`RERANK=true`, `Reranker.enabled?`). When on,
  `GenerateAnswerJob` retrieves the wider pool (`DEFAULT_CANDIDATE_K`) and the
  reranker narrows it; when off, nothing changes. The deterministic CI eval runs
  with it off so recall/MRR stay gatable.
- **Determinism in tests.** `FakeLlmClient` recognises the re-rank prompt (a
  stable marker in the system message) and echoes the candidate order — an
  identity reorder — so the offline suite stays green while still exercising the
  parse/apply path. Real-key runs exercise the genuine semantic reorder.
- **Observability.** Each re-rank emits one structured `rerank` log line
  (candidate count, kept count, a `fell_back` flag, latency) via `RetrievalLogger`
  — counts/timings only, no content, matching the existing privacy rule.

## Consequences

- **Implemented, measured, and defaulted off — on evidence.** On the ADR 0005
  harness (k=8, text-embedding-3-small), hybrid already reaches **MRR 1.00 /
  recall@8 1.00** on this corpus, so there is no headroom for re-rank to add — and
  in practice it *mildly regressed* the hard subset (**MRR 1.00 → 0.83**) by
  re-promoting a fluent, generic passage above the buried record that actually
  answered the question. That is a known LLM-re-ranker failure mode, and it is
  exactly why re-rank ships **off**: on a small, high-quality corpus the hybrid
  ordering is already at ceiling and a second opinion only adds cost, latency, and
  a chance to be wrong.
- **The value is real but conditional.** Two-stage re-rank pays off when the first
  stage is *high-recall but poorly-ordered* — large/noisy corpora, weak
  first-stage ranking, long candidate pools. The plumbing (wide-pool retrieve →
  reorder → narrow) is in place and a single ENV flip turns it on where that
  holds; the honest reading is that this corpus is not that case.
- **Single responsibility preserved.** `Retriever` stays pure and deterministic;
  the online, paid, non-deterministic concern lives in its own opt-in service with
  a never-worse-than-fused guarantee.
- **Cost note.** The re-rank call's tokens are not tied to a persisted `message`,
  so they don't flow into the `/dashboard` per-message cost view; its latency is
  captured in the `rerank` log line. Wiring re-rank cost into the dashboard is a
  small, deliberately deferred follow-up.
