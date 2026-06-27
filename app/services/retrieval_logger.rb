# frozen_string_literal: true

# Structured, one-line-per-event logging for the online query path
# (RAG_ASSISTANT_ARCHITECTURE.md §10: "log retrieval scores and timings per
# query for debuggability"). Each event is a single JSON object emitted via
# Rails.logger, so the lines are greppable and feedable to a log pipeline.
#
# Privacy: we deliberately log lengths, ids, scores and timings — never the raw
# query text or chunk content. The query is a user's words and chunk content is
# untrusted uploaded text; neither belongs in the logs. Keep it that way.
module RetrievalLogger
  module_function

  # One line per retrieval: how it was scoped, what it found, how long it took.
  # +mode+ is "hybrid" or "dense"; +dense_ms+ / +lexical_ms+ time the two legs
  # separately (lexical_ms is absent in dense mode, dropped by +compact+).
  # Scores/timings only, no content.
  def log_retrieval(tenant:, query:, k:, result:, embedding_ms:, dense_ms:, lexical_ms: nil, mode: "dense")
    emit("retrieval",
      tenant_id: tenant&.id,
      query_length: query.to_s.length,
      mode: mode,
      k: k,
      abstained: result.abstained?,
      results: result.scored.length,
      top_similarity: round3(result.top_similarity),
      embedding_ms: embedding_ms,
      dense_ms: dense_ms,
      lexical_ms: lexical_ms)
  end

  # One line per LLM re-rank (ADR 0008): how many candidates it reordered, how
  # many it kept, whether it fell back to the fused order (parse failure / empty),
  # and how long the model call took. Counts/timings only, no content.
  def log_rerank(candidates:, kept:, fell_back:, rerank_ms:)
    emit("rerank",
      candidates: candidates,
      kept: kept,
      fell_back: fell_back,
      rerank_ms: rerank_ms)
  end

  # One line per answer generation: model, token usage, timing, and how many
  # chunks grounded it. No prompt or answer text.
  def log_generation(message:, chunk_count:, generation_ms:)
    emit("generation",
      message_id: message.id,
      conversation_id: message.conversation_id,
      model: message.model,
      prompt_tokens: message.prompt_tokens,
      completion_tokens: message.completion_tokens,
      chunk_count: chunk_count,
      generation_ms: generation_ms)
  end

  def emit(event, **fields)
    Rails.logger.info({ event: event, **fields.compact }.to_json)
  end

  def round3(value)
    value && value.round(3)
  end
end
