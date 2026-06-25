# 5. Evaluation harness

Date: 2026-06-25

## Status

Accepted

## Context

Phases 0–3 produced a working RAG loop, but "the answers seem good" is not a
measurable property. Changing the chunker, the relevance floor, `k`, or the
answer prompt could improve or regress quality and we would not know. The
architecture (RAG_ASSISTANT_ARCHITECTURE.md §2, §9) calls an offline evaluation
harness the primary senior differentiator and requires: retrieval metrics
(recall@k, MRR), an answer-quality signal (LLM-as-judge), an abstention check for
out-of-corpus questions, and a report so a change shows a measurable delta. Forces:

- Tests must be **deterministic and offline** (§11) — every LLM/network call is
  stubbed via `FakeLlmClient`, whose embeddings only match on *verbatim* text.
- A useful tool must also produce a **semantic** signal on natural-language
  questions, which only a real embedding model can give.
- The LLM-judge is non-deterministic, costs live calls, and has known biases
  (length, self-preference).
- The harness must not pollute or depend on dev/prod data.

## Decision

Add an `Eval` service namespace (`app/services/eval/`) — `Dataset`, `CorpusSeeder`,
`Metrics`, `Judge`, `Runner`, `Report` — plus fixtures in `spec/fixtures/eval/`
and a `rake eval` / `rake eval:retrieval` task. Key choices:

1. **Gold sources identified by content marker, not chunk id.** A question names
   its expected source(s) by short verbatim substrings (`expected_markers`) the
   correct chunk must contain. Chunk ids and boundaries change on every re-chunk —
   exactly the change the harness exists to measure — so pinning gold to ids would
   break the metric on the change under test. Markers survive re-chunking.

2. **Seed-and-rollback inside one `requires_new: true` transaction.** The runner
   creates an ephemeral tenant + documents, ingests them **synchronously** through
   the real `DocumentIngestor`, runs the eval, then `raise ActiveRecord::Rollback`.
   Nothing persists; every run starts from an identical corpus with no cleanup task
   to forget. `requires_new: true` makes the rollback work even inside an outer
   transaction (RSpec's transactional fixtures), which a plain nested transaction
   would not. Ingestion is inline, not via `IngestDocumentJob`, because a job runs
   on a different DB connection that cannot see the uncommitted transaction. Cost:
   embeddings are recomputed each run — negligible for a small fixture set; an
   embedding cache is deferred.

3. **Two backends, two purposes; recall@k stays deterministic and CI-gateable.**
   Under the Fake (CI/default), embeddings are digest-deterministic, so recall@k /
   MRR / abstention are exactly reproducible and gateable as a *regression*
   baseline — with the caveat that the Fake only retrieves on verbatim text, so its
   numbers measure plumbing, not semantics. The real embedding model (key present)
   produces the meaningful semantic numbers on natural-language questions; run it
   manually or nightly. CI gates the deterministic baseline; the real run is the
   quality signal.

4. **LLM-judge is directional, not a hard CI gate.** `Eval::Judge` grades an answer
   against the reference on faithfulness + relevance (1–5) via a no-block
   `LlmClient.stream_chat` call, parsing the JSON verdict defensively (malformed →
   nil score, excluded from the mean, never crashes a run); `SAMPLES` averages
   several grades to reduce flap. Because it is non-deterministic and biased, the
   harness reports it but does not gate CI on it.

5. **Answers come from the real `AnswerGenerator`.** For judging, the runner builds
   a throwaway conversation + assistant message (inside the rollback) and runs the
   production generator, so the score reflects the answer users actually get —
   including its abstention behaviour — rather than a parallel re-implementation.

6. **Report = stdout table always; optional JSON artifact + threshold gate.**
   `rake eval` prints an aligned summary table; `FORMAT=json` also writes
   `tmp/eval/report-<ts>.json` for diffing runs. `MIN_RECALL` / `MIN_MRR` /
   `MIN_ABSTENTION` make the task exit non-zero when unmet, so CI can gate.

## Consequences

- Chunking/retrieval/prompt changes now produce a number that moves; `MIN_SIMILARITY`
  and `K` are task knobs (already `Retriever` parameters), so sweeping the floor
  needs no code change.
- The deterministic suite covers the metric math, the judge's parsing (including
  malformed output), and a full `Runner` smoke run that asserts perfect baseline
  recall/MRR, correct abstention, **and that the eval leaves no DB residue**.
- The recall numbers from a Fake run are a regression baseline, not a semantic
  score; reading them as semantic quality would mislead. The README and this ADR
  name that explicitly.
- The LLM-judge can disagree run to run; treated as directional, that is acceptable.
- Validation in `Dataset` fails loudly on a marker absent from the corpus, so a
  fixture typo surfaces instead of masquerading as a recall miss.
- **Abstention detection must match the refusal vocabulary the prompt induces.**
  The system declines in two layers — the Retriever's floor (canned
  `ABSTAIN_MESSAGE`) and the model refusing in its own words. Because
  `AnswerGenerator::SYSTEM_PROMPT` instructs the model to say "I don't know", the
  runner counts the floor message **or** an "I don't know" refusal as a decline.
  An exact-string check on only the canned message read a correct model refusal as
  a fabrication and reported abstention 0.33 when the true value was 1.00 — found
  by capturing the generated answer into the report row (now part of the JSON
  artifact) so near-miss OOC answers can be eyeballed.
