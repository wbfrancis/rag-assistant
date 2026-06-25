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
    EMBEDDINGS_URL       = "https://api.openai.com/v1/embeddings"
    CHAT_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions"

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

    # Streams a chat completion over Server-Sent Events. Yields each content
    # delta as it arrives and returns the fully assembled answer, matching the
    # FakeLlmClient contract so the rest of the app is oblivious to which backend
    # is wired. `messages` is an array of { role:, content: } hashes.
    def stream_chat(messages, model:, &block)
      full = +""
      stream(CHAT_COMPLETIONS_URL, model: model, messages: messages, stream: true) do |event|
        delta = event.dig("choices", 0, "delta", "content")
        next if delta.nil? || delta.empty?

        full << delta
        block&.call(delta)
      end
      full
    end

    private

    # POST a streaming request and yield each parsed SSE data event. Reads the
    # response body incrementally so tokens surface as the model produces them.
    def stream(url, payload)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = @timeout
      http.read_timeout = @timeout

      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "text/event-stream"
      request.body = JSON.generate(payload)

      buffer = +""
      http.request(request) do |response|
        raise error_for(response.code, response.read_body) unless response.code.to_i == 200

        response.read_body do |segment|
          buffer << segment
          while (newline = buffer.index("\n"))
            line = buffer.slice!(0..newline)
            event = parse_sse_line(line)
            return if event == :done

            yield event unless event.nil?
          end
        end
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError, e.message
    end

    # One SSE line → a parsed JSON event, :done on the terminal sentinel, or nil
    # for blank/comment lines we ignore.
    def parse_sse_line(line)
      line = line.strip
      return nil unless line.start_with?("data:")

      data = line.delete_prefix("data:").strip
      return :done if data == "[DONE]"

      JSON.parse(data)
    end

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
      return JSON.parse(response.body) if response.code.to_i == 200

      raise error_for(response.code, response.body)
    end

    # Map an HTTP status to LlmClient's error taxonomy: 429 / 5xx are transient
    # (retryable via LlmClient#with_retries), everything else is permanent.
    def error_for(code, body)
      case code.to_i
      when 429
        RateLimitError.new(body.to_s)
      when 500..599
        RateLimitError.new("OpenAI #{code}: #{body}")
      else
        Error.new("OpenAI #{code}: #{body}")
      end
    end
  end
end
