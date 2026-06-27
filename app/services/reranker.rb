# frozen_string_literal: true

require "json"

# Reranker is the optional *second stage* of retrieval (ADR 0008). The Retriever's
# hybrid first stage is cheap and high-recall but only approximately ordered (RRF
# fuses two rankings without ever seeing the query's meaning against a full
# passage). This stage hands the fused candidate pool to the LLM and asks it to
# reorder them by relevance, so the single best chunk lands at rank 1 — lifting
# MRR and the context the answer is grounded in.
#
# It lives *outside* the Retriever on purpose (ADR 0008): the Retriever stays
# single-responsibility and deterministic (pure dense+lexical SQL), and re-rank —
# an online, paid, non-deterministic model call — is an answer-side concern the
# caller opts into. +GenerateAnswerJob+ and the eval harness wrap a +Retriever+
# result with a +Reranker+ when re-rank is enabled.
#
# Two guarantees:
#   * **Never worse than the fused order.** On any parse failure, empty model
#     output, or a result with nothing to reorder, it returns the fused order
#     untouched. Re-rank can only help; a flaky model call can't degrade recall.
#   * **No new LLM seam.** It reuses +LlmClient.stream_chat+ (called without a
#     block for a plain completion), asking for a compact JSON array of candidate
#     indices so parsing is cheap and deterministic.
#
# Determinism in tests: the +FakeLlmClient+ recognises the re-rank prompt and
# echoes the candidate order (identity), so the deterministic suite stays green;
# real-key runs exercise the genuine semantic reorder.
class Reranker
  # Sentinel in the system prompt the FakeLlmClient keys off to return a
  # deterministic ordering instead of canned chat tokens.
  RERANK_MARKER = "You are a search result re-ranker."

  # Per-candidate snippet length sent to the model. Enough to judge relevance,
  # short enough to keep the (top-~20) prompt cheap.
  SNIPPET_CHARS = 320

  SYSTEM_PROMPT = <<~PROMPT.strip
    #{RERANK_MARKER}
    You are given a user query and a numbered list of candidate passages. Rank the
    passages by how directly each one answers the SPECIFIC question. A passage that
    actually contains the specific entity, identifier, code, name, or value the
    question asks about must rank above a passage that only describes the topic in
    general or defines what such a thing is. Respond with ONLY a compact JSON array
    of the candidate numbers in that order, e.g. [3,0,1,2]. Include every candidate
    number exactly once. No prose, no code fences.
  PROMPT

  # Whether re-rank is enabled. Off by default (it adds online latency + cost and
  # non-determinism); flip on with +RERANK=true+. The deterministic CI eval runs
  # with it off so recall/MRR stay gatable.
  def self.enabled?
    ENV.fetch("RERANK", "false") == "true"
  end

  # @param query [String] the standalone query the candidates were retrieved for.
  # @param result [Retriever::Result] the fused first-stage result to reorder.
  # @param k [Integer, nil] keep at most this many after reordering; nil keeps all.
  # @param model [String] chat model to score with.
  def initialize(query:, result:, k: nil, model: LlmClient.config.chat_model)
    @query  = query.to_s
    @result = result
    @k      = k
    @model  = model
  end

  # Returns a new Retriever::Result with +scored+ reordered (and optionally capped
  # to +k+). Abstention and +top_similarity+ are carried through untouched —
  # re-rank only reorders, it never changes the decision to answer or abstain.
  def call
    candidates = @result.scored
    # Nothing to do: an abstention, or 0–1 candidates. Skip the model call
    # entirely (saves cost and keeps the abstain path deterministic).
    return @result if @result.abstained? || candidates.length <= 1

    started   = monotonic
    order     = request_order(candidates)
    rerank_ms = elapsed_ms(started)
    fell_back = order.nil?

    reordered = (fell_back ? candidates : reorder(candidates, order))
    reordered = reordered.first(@k) if @k

    RetrievalLogger.log_rerank(
      candidates: candidates.length, kept: reordered.length,
      fell_back: fell_back, rerank_ms: rerank_ms
    )

    Result.new(scored: reordered, abstained: @result.abstained, top_similarity: @result.top_similarity)
  end

  private

  Result = Retriever::Result

  # Ask the model for an ordering; returns an Array of valid, unique candidate
  # indices, or nil to signal "fall back to the fused order". Any exception
  # (network, etc.) is *not* swallowed here — transient LLM errors propagate so
  # the job's existing retry/backoff handles them; only a malformed or empty
  # *response* triggers the fallback.
  def request_order(candidates)
    raw = LlmClient.stream_chat(prompt_messages(candidates), model: @model)
    parse_order(raw, candidates.length)
  end

  # Extract the first JSON array of integers from the model's reply and keep only
  # the in-range, first-seen indices. Returns nil when nothing usable is found.
  def parse_order(raw, count)
    match = raw.to_s[/\[[\s\d,]*\]/]
    return nil unless match

    indices = JSON.parse(match)
    return nil unless indices.is_a?(Array)

    valid = indices.select { |i| i.is_a?(Integer) && i.between?(0, count - 1) }.uniq
    valid.empty? ? nil : valid
  rescue JSON::ParserError
    nil
  end

  # Place the model-ranked candidates first, then append any it omitted in their
  # original fused order — so a model that drops candidates never loses recall.
  def reorder(candidates, order)
    picked    = order.map { |i| candidates[i] }
    remaining = candidates.each_index.reject { |i| order.include?(i) }.map { |i| candidates[i] }
    picked + remaining
  end

  def prompt_messages(candidates)
    [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: user_content(candidates) }
    ]
  end

  def user_content(candidates)
    listing = candidates.each_with_index.map do |(chunk, _similarity), i|
      "[#{i}] #{chunk.content.to_s.gsub(/\s+/, ' ').strip.truncate(SNIPPET_CHARS)}"
    end

    <<~CONTENT.strip
      Query: #{@query}

      Candidates:
      #{listing.join("\n")}

      Return the JSON array of candidate numbers, most relevant first.
    CONTENT
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started)
    ((monotonic - started) * 1000).round
  end
end
