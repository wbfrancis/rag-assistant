require "net/http"
require "json"

class LlmClient
  # A small, dependency-light real backend that calls OpenAI's embeddings API
  # directly over HTTP. It satisfies the same duck-typed interface as
  # FakeLlmClient (embed / stream_chat) and translates transient HTTP failures
  # into LlmClient's retryable error types so `with_retries` handles them.
  #
  # The thin slice only needs embeddings; stream_chat is intentionally a stub
  # until Phase 3.
  class OpenaiBackend
    EMBEDDINGS_URL = "https://api.openai.com/v1/embeddings"

    def self.api_key
      key = nil
      if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
        key = Rails.application.credentials.openai_api_key
      end
      key || ENV["OPENAI_API_KEY"]
    end

    def initialize(api_key: self.class.api_key, timeout: 30)
      @api_key = api_key
      @timeout = timeout
      raise NotConfiguredError, "No OpenAI API key set (credentials.openai_api_key or OPENAI_API_KEY)." if @api_key.to_s.empty?
    end

    # Returns one vector per input, preserving input order.
    def embed(texts, model:)
      response = post(EMBEDDINGS_URL, model: model, input: Array(texts))
      response.fetch("data").sort_by { |row| row.fetch("index") }.map { |row| row.fetch("embedding") }
    end

    def stream_chat(_messages, model:, &_block)
      raise NotConfiguredError, "OpenaiBackend implements embeddings only in the Phase 1 thin slice (chat lands in Phase 3)."
    end

    private

    def post(url, payload)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = @timeout
      http.read_timeout = @timeout

      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)

      handle(http.request(request))
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError, e.message
    end

    def handle(response)
      case response.code.to_i
      when 200
        JSON.parse(response.body)
      when 429
        raise RateLimitError, response.body
      when 500..599
        raise RateLimitError, "OpenAI #{response.code}: #{response.body}"
      else
        raise Error, "OpenAI #{response.code}: #{response.body}"
      end
    end
  end
end
