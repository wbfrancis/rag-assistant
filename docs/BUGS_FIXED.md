# Bugs Fixed — running log

A running record of real bugs found and fixed during development of `rag-assistant`,
newest first. "Product bug" = defect in the application under test; "Eval/test bug"
= defect in the measurement/test harness itself (which can be just as misleading).

| # | Date | Phase | Type | Bug | Root cause | Fix |
|---|------|-------|------|-----|-----------|-----|
| 3 | 2026-06-25 | 4 | Eval bug | Eval reported **abstention accuracy 0.33** on out-of-corpus questions, implying the system fabricated answers to near-miss questions. | Abstention was detected by an **exact string match** on the canned `AnswerGenerator::ABSTAIN_MESSAGE`. The model actually declined correctly in its own words ("I don't know."), which the exact match missed — a metric false-negative, not a product defect. | `Eval::Runner#declined?` now also matches a `REFUSAL = /\bi don't know\b/i` answer (the phrase `AnswerGenerator::SYSTEM_PROMPT` instructs the model to emit). Abstention → 1.00. Also capture the generated answer into report rows so OOC answers can be eyeballed. (ADR 0005) |
| 2 | 2026-06-25 | 4 | Eval bug | `Eval::Runner` measured abstention from `Retriever.abstained?` **only**, ignoring the generation-layer guardrail — so a question that cleared the relevance floor but was declined by the model at answer time was not counted as a decline. | Implementation diverged from the plan/ADR, which specified declined = floor-abstain **OR** generated answer is a refusal. Only the floor half was wired. | Refactored `evaluate` to generate the answer once (when judging) and reuse it for both abstention and the judge: `declined = retrieval.abstained? \|\| <refusal>`. |
| 1 | (Phase 3) | 3 | Product bug | Multi-turn follow-up questions retrieved the wrong chunks — the query was being contextualized against **itself**. | `QueryContextualizer` built its history from the conversation's messages, which already included the just-persisted user message, so it condensed the new question against a copy of itself. | Pass `current_message:` so the just-persisted user message is excluded from the history used for contextualization. (Found by a test.) |

## How to use this log

- Append a new top row for each genuine bug fixed (not refactors, renames, or planned features).
- Note whether it was a **product** bug or an **eval/test** bug — the latter are easy to miss and
  often more dangerous, because they make a broken system look healthy or a healthy one look broken.
- Link the ADR or commit where relevant.
