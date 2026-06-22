# frozen_string_literal: true

# LlmClient is the single, narrow seam between the application and whatever LLM
# provider backs it. Per RAG_ASSISTANT_ARCHITECTURE.md §3, *all* retry, backoff,
# timeout and fallback logic lives here so that swapping providers later only
# touches this class (and its backend).
#
# Phase 0 ships the interface plus a deterministic test Fake only. The default
# real backend is a +PendingBackend+ that raises +NotConfiguredError+, so
# production code can never silently no-op before a real provider is wired in
# Phase 1.
class LlmClient
  # --- Error hierarchy -------------------------------------------------------
  class Error < StandardError; end
  # Transient: provider asked us to slow down. Retryable.
  class RateLimitError < Error; end
  # Transient: request exceeded the configured timeout. Retryable.
  class TimeoutError < Error; end
  # Permanent: no real provider backend is wired up yet. Not retryable.
  class NotConfiguredError < Error; end

  # Retryable, transient failures. Anything else is re-raised immediately.
  RETRYABLE_ERRORS = [ RateLimitError, TimeoutError ].freeze

  # Resolved configuration, read from Rails credentials / ENV at first use.
  Config = Struct.new(
    :chat_model,
    :embedding_model,
    :embedding_dim,
    :fallback_chat_model,
    :fallback_embedding_model,
    :max_retries,
    :timeout_s,
    keyword_init: true
  )

  # The default backend: refuses to do anything until a real provider is wired.
  class PendingBackend
    MESSAGE = "LlmClient has no real provider backend; one is wired in Phase 1. " \
              "Set LlmClient.backend (e.g. to a FakeLlmClient) in tests."

    def embed(_texts, **)
      raise NotConfiguredError, MESSAGE
    end

    def stream_chat(_messages, **)
      raise NotConfiguredError, MESSAGE
    end
  end

  class << self
    # The pluggable provider backend. Tests assign a FakeLlmClient here.
    attr_writer :backend

    def backend
      @backend ||= PendingBackend.new
    end

    def config
      @config ||= build_config
    end

    # Reset memoized state — used by the test suite between examples.
    def reset!
      @config = nil
      @backend = nil
    end

    # Embed one or more texts. Always returns an Array of vectors (one per
    # input), each of length config.embedding_dim.
    #
    #   LlmClient.embed("hello")            #=> [[0.1, ...]]
    #   LlmClient.embed(["a", "b"])         #=> [[...], [...]]
    def embed(texts, model: config.embedding_model)
      inputs = Array(texts)
      with_retries(model: model, fallback_model: config.fallback_embedding_model) do |active_model|
        backend.embed(inputs, model: active_model)
      end
    end

    # Stream a chat completion. Yields each token as it arrives and returns the
    # fully assembled string.
    #
    #   LlmClient.stream_chat(messages) { |tok| print tok } #=> "full text"
    def stream_chat(messages, model: config.chat_model, &block)
      with_retries(model: model, fallback_model: config.fallback_chat_model) do |active_model|
        backend.stream_chat(messages, model: active_model, &block)
      end
    end

    private

    # Bounded retry with exponential backoff. Retries transient errors up to
    # config.max_retries times on the primary model; if those are exhausted and
    # a fallback model is configured, switches to it (with its own retry budget)
    # for one final round before giving up.
    def with_retries(model:, fallback_model: nil)
      current_model = model
      attempt = 0
      used_fallback = false

      begin
        attempt += 1
        yield(current_model)
      rescue *RETRYABLE_ERRORS => e
        if attempt <= config.max_retries
          sleep(backoff_seconds(attempt))
          retry
        elsif fallback_model && !used_fallback && fallback_model != current_model
          used_fallback = true
          current_model = fallback_model
          attempt = 0
          retry
        else
          raise e
        end
      end
    end

    # Exponential backoff: 2^(attempt-1) * 0.5s (0.5s, 1s, 2s, ...). `sleep` is
    # called on self so specs can stub it for instant runs.
    def backoff_seconds(attempt)
      (2**(attempt - 1)) * 0.5
    end

    def build_config
      creds = credentials_for(:llm)

      Config.new(
        chat_model: setting(creds, :chat_model, "LLM_CHAT_MODEL", "gpt-4o-mini"),
        embedding_model: setting(creds, :embedding_model, "LLM_EMBEDDING_MODEL", "text-embedding-3-small"),
        embedding_dim: Integer(setting(creds, :embedding_dim, "LLM_EMBEDDING_DIM", 1536)),
        fallback_chat_model: setting(creds, :fallback_chat_model, "LLM_FALLBACK_CHAT_MODEL", nil),
        fallback_embedding_model: setting(creds, :fallback_embedding_model, "LLM_FALLBACK_EMBEDDING_MODEL", nil),
        max_retries: Integer(setting(creds, :max_retries, "LLM_MAX_RETRIES", 2)),
        timeout_s: Float(setting(creds, :timeout_s, "LLM_TIMEOUT_S", 30))
      )
    end

    # Credentials take precedence, then ENV, then the hard-coded default.
    def setting(creds, key, env_var, default)
      value = creds[key]
      value = ENV[env_var] if value.nil?
      value.nil? ? default : value
    end

    def credentials_for(key)
      return {} unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

      Rails.application.credentials.public_send(key) || {}
    rescue StandardError
      {}
    end
  end
end
