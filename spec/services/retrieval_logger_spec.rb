require "rails_helper"

RSpec.describe RetrievalLogger do
  describe ".log_retrieval" do
    it "emits one JSON line with scores/timings and never the raw query text" do
      user   = create(:user)
      result = Retriever::Result.new(scored: [ [ double("chunk"), 0.42 ] ], abstained: false, top_similarity: 0.4242)

      expect(Rails.logger).to receive(:info) do |line|
        parsed = JSON.parse(line)
        expect(parsed["event"]).to eq("retrieval")
        expect(parsed["tenant_id"]).to eq(user.id)
        expect(parsed["mode"]).to eq("hybrid")
        expect(parsed["results"]).to eq(1)
        expect(parsed["abstained"]).to be(false)
        expect(parsed["top_similarity"]).to eq(0.424) # rounded to 3 dp
        expect(parsed["query_length"]).to eq("super secret question".length)
        expect(parsed["embedding_ms"]).to eq(5)
        expect(parsed["dense_ms"]).to eq(7)
        expect(parsed["lexical_ms"]).to eq(3)
        expect(line).not_to include("super secret question")
      end

      described_class.log_retrieval(
        tenant: user, query: "super secret question", k: 8, mode: "hybrid",
        result: result, embedding_ms: 5, dense_ms: 7, lexical_ms: 3
      )
    end

    it "omits lexical_ms in dense mode" do
      user   = create(:user)
      result = Retriever::Result.new(scored: [], abstained: true, top_similarity: 0.1)

      expect(Rails.logger).to receive(:info) do |line|
        parsed = JSON.parse(line)
        expect(parsed["mode"]).to eq("dense")
        expect(parsed).not_to have_key("lexical_ms")
      end

      described_class.log_retrieval(
        tenant: user, query: "q", k: 8, mode: "dense",
        result: result, embedding_ms: 1, dense_ms: 2
      )
    end
  end

  describe ".log_rerank" do
    it "emits one JSON line with counts/timing and a fell_back flag, no content" do
      expect(Rails.logger).to receive(:info) do |line|
        parsed = JSON.parse(line)
        expect(parsed["event"]).to eq("rerank")
        expect(parsed["candidates"]).to eq(20)
        expect(parsed["kept"]).to eq(8)
        expect(parsed["fell_back"]).to be(false)
        expect(parsed["rerank_ms"]).to eq(42)
      end

      described_class.log_rerank(candidates: 20, kept: 8, fell_back: false, rerank_ms: 42)
    end
  end

  describe ".log_generation" do
    it "emits one JSON line with token usage and never the answer text" do
      message = create(:message, :assistant,
        content: "the confidential answer", model: "gpt-4o-mini",
        prompt_tokens: 100, completion_tokens: 20)

      expect(Rails.logger).to receive(:info) do |line|
        parsed = JSON.parse(line)
        expect(parsed["event"]).to eq("generation")
        expect(parsed["model"]).to eq("gpt-4o-mini")
        expect(parsed["prompt_tokens"]).to eq(100)
        expect(parsed["completion_tokens"]).to eq(20)
        expect(parsed["chunk_count"]).to eq(2)
        expect(line).not_to include("confidential answer")
      end

      described_class.log_generation(message: message, chunk_count: 2, generation_ms: 50)
    end
  end
end
