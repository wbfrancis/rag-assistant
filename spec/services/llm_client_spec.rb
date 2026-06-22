# frozen_string_literal: true

require "rails_helper"

RSpec.describe LlmClient do
  # Make backoff instant; assert it is exercised where relevant.
  before { allow(described_class).to receive(:sleep) }

  describe ".embed" do
    before { described_class.backend = FakeLlmClient.new }

    it "returns one vector per input text" do
      vectors = described_class.embed([ "alpha", "beta", "gamma" ])

      expect(vectors.length).to eq(3)
    end

    it "returns vectors of length embedding_dim" do
      vectors = described_class.embed([ "alpha", "beta" ])

      expect(vectors).to all(have_attributes(length: described_class.config.embedding_dim))
    end

    it "wraps a single string in a one-element result" do
      expect(described_class.embed("solo").length).to eq(1)
    end

    it "is deterministic: the same text yields the same vector across calls" do
      first = described_class.embed("repeatable").first
      second = described_class.embed("repeatable").first

      expect(second).to eq(first)
    end

    it "produces different vectors for different texts" do
      a = described_class.embed("alpha").first
      b = described_class.embed("beta").first

      expect(a).not_to eq(b)
    end
  end

  describe ".stream_chat" do
    let(:fake) { FakeLlmClient.new(chat_tokens: %w[The quick brown fox]) }

    before { described_class.backend = fake }

    it "yields tokens in order" do
      yielded = []
      described_class.stream_chat([ { role: "user", content: "hi" } ]) { |token| yielded << token }

      expect(yielded).to eq(%w[The quick brown fox])
    end

    it "returns the concatenation of the streamed tokens" do
      result = described_class.stream_chat([ { role: "user", content: "hi" } ]) { |_| }

      expect(result).to eq("Thequickbrownfox")
    end
  end

  describe "retry behaviour" do
    it "retries transient RateLimitError, then succeeds" do
      fake = FakeLlmClient.new(fail_times: 2, error_class: LlmClient::RateLimitError)
      described_class.backend = fake

      described_class.embed("text")

      # 2 failed attempts + 1 success.
      expect(fake.calls).to eq(3)
    end

    it "retries transient TimeoutError, then succeeds" do
      fake = FakeLlmClient.new(fail_times: 1, error_class: LlmClient::TimeoutError)
      described_class.backend = fake

      expect { described_class.embed("text") }.not_to raise_error
      expect(fake.calls).to eq(2)
    end

    it "sleeps with exponential backoff between attempts" do
      described_class.backend = FakeLlmClient.new(fail_times: 2)

      described_class.embed("text")

      expect(described_class).to have_received(:sleep).with(0.5).ordered
      expect(described_class).to have_received(:sleep).with(1.0).ordered
    end

    it "raises after max_retries is exhausted" do
      described_class.config.max_retries = 1
      described_class.backend = FakeLlmClient.new(fail_times: Float::INFINITY)

      expect { described_class.embed("text") }.to raise_error(LlmClient::RateLimitError)
    end

    it "does not retry on a non-retryable error" do
      fake = FakeLlmClient.new(fail_times: 1, error_class: LlmClient::Error)
      described_class.backend = fake

      expect { described_class.embed("text") }.to raise_error(LlmClient::Error)
      expect(fake.calls).to eq(1)
    end
  end

  describe "fallback model" do
    it "falls back to the configured fallback model on final failure" do
      described_class.config.max_retries = 1
      described_class.config.embedding_model = "primary-embed"
      described_class.config.fallback_embedding_model = "fallback-embed"
      fake = FakeLlmClient.new(failing_models: [ "primary-embed" ])
      described_class.backend = fake

      vectors = described_class.embed("text")

      expect(vectors.length).to eq(1)
      expect(fake.models_used.last).to eq("fallback-embed")
    end

    it "raises when the fallback model also fails" do
      described_class.config.max_retries = 1
      described_class.config.embedding_model = "primary-embed"
      described_class.config.fallback_embedding_model = "fallback-embed"
      fake = FakeLlmClient.new(failing_models: %w[primary-embed fallback-embed])
      described_class.backend = fake

      expect { described_class.embed("text") }.to raise_error(LlmClient::RateLimitError)
    end
  end

  describe "default backend" do
    it "raises NotConfiguredError so production code can't silently no-op" do
      expect { described_class.embed("text") }.to raise_error(LlmClient::NotConfiguredError)
    end

    it "raises NotConfiguredError for stream_chat too" do
      expect { described_class.stream_chat([]) { |_| } }.to raise_error(LlmClient::NotConfiguredError)
    end
  end

  describe ".config" do
    it "defaults embedding_dim to 1536" do
      expect(described_class.config.embedding_dim).to eq(1536)
    end
  end
end
