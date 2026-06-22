# frozen_string_literal: true

require "digest"

# Deterministic, offline backend for LlmClient used throughout the test suite.
#
# - +embed+ returns reproducible vectors derived from a digest of each input, so
#   the same text always yields the same vector (stable retrieval tests).
# - +stream_chat+ yields a canned sequence of tokens and returns their join.
# - Failure injection (+fail_times+ / +failing_models+) exercises the retry,
#   backoff and fallback paths without any network.
class FakeLlmClient
  CANNED_TOKENS = [ "Hello", ",", " ", "world", "!" ].freeze

  attr_reader :calls, :models_used, :embed_calls, :chat_calls

  # @param embedding_dim [Integer] length of returned vectors (defaults to the
  #   client's configured dim so specs and the adapter stay in lock-step).
  # @param fail_times [Numeric] raise +error_class+ for the first N calls, then
  #   succeed. Pass +Float::INFINITY+ for an "always fails" backend.
  # @param error_class [Class] which retryable error to raise on failure.
  # @param failing_models [Array<String>] always raise when called with one of
  #   these models (used to force a fallback to a different model).
  # @param chat_tokens [Array<String>] the token sequence stream_chat yields.
  def initialize(embedding_dim: LlmClient.config.embedding_dim,
                 fail_times: 0,
                 error_class: LlmClient::RateLimitError,
                 failing_models: [],
                 chat_tokens: CANNED_TOKENS)
    @embedding_dim = embedding_dim
    @fail_times = fail_times
    @error_class = error_class
    @failing_models = Array(failing_models)
    @chat_tokens = chat_tokens
    @calls = 0
    @embed_calls = 0
    @chat_calls = 0
    @models_used = []
  end

  def embed(texts, model: nil)
    register_call(model)
    @embed_calls += 1
    Array(texts).map { |text| deterministic_vector(text) }
  end

  def stream_chat(_messages, model: nil)
    register_call(model)
    @chat_calls += 1
    @chat_tokens.each { |token| yield token if block_given? }
    @chat_tokens.join
  end

  private

  def register_call(model)
    @calls += 1
    @models_used << model

    if @failing_models.include?(model)
      raise @error_class, "FakeLlmClient: model #{model.inspect} is configured to fail"
    end

    return if @calls > @fail_times

    raise @error_class, "FakeLlmClient: injected failure ##{@calls}"
  end

  # Seed a PRNG from a digest of the text so identical inputs map to identical
  # vectors. Values are in [-1.0, 1.0).
  def deterministic_vector(text)
    seed = Digest::SHA256.hexdigest(text.to_s).to_i(16) % (2**32)
    prng = Random.new(seed)
    Array.new(@embedding_dim) { prng.rand(-1.0...1.0) }
  end
end

RSpec.configure do |config|
  # Reset the adapter's memoized backend/config after every example so a Fake
  # installed by one spec never leaks into another.
  config.after { LlmClient.reset! }
end
