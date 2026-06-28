require "rails_helper"

# Reranker reorders a fused candidate list via one LLM call that returns a JSON
# array of indices. These examples stub LlmClient.stream_chat directly so each
# model "ordering" (and each malformed reply) is exercised in isolation; the
# guarantee under test is *never worse than the fused order*.
RSpec.describe Reranker do
  def chunk(id, content)
    double("chunk", id: id, content: content)
  end

  def result_of(pairs, abstained: false, top_similarity: 0.9)
    Retriever::Result.new(scored: pairs, abstained: abstained, top_similarity: top_similarity)
  end

  let(:candidates) do
    [ [ chunk("a", "alpha"), 0.9 ], [ chunk("b", "bravo"), 0.5 ], [ chunk("c", "charlie"), 0.2 ] ]
  end

  describe "#call" do
    it "reorders the candidates to match the model's index array" do
      allow(LlmClient).to receive(:stream_chat).and_return("[2,0,1]")

      reranked = described_class.new(query: "q", result: result_of(candidates)).call

      expect(reranked.chunks.map(&:id)).to eq(%w[c a b])
    end

    it "caps the reordered list to k" do
      allow(LlmClient).to receive(:stream_chat).and_return("[2,0,1]")

      reranked = described_class.new(query: "q", result: result_of(candidates), k: 2).call

      expect(reranked.chunks.map(&:id)).to eq(%w[c a])
    end

    it "appends candidates the model omitted, in their original order (never drops)" do
      allow(LlmClient).to receive(:stream_chat).and_return("[2]")

      reranked = described_class.new(query: "q", result: result_of(candidates)).call

      expect(reranked.chunks.map(&:id)).to eq(%w[c a b])
    end

    it "tolerates prose/code-fence wrapping around the JSON array" do
      allow(LlmClient).to receive(:stream_chat).and_return("Sure! ```\n[1,0,2]\n``` done")

      reranked = described_class.new(query: "q", result: result_of(candidates)).call

      expect(reranked.chunks.map(&:id)).to eq(%w[b a c])
    end

    it "falls back to the fused order when the reply has no JSON array" do
      allow(LlmClient).to receive(:stream_chat).and_return("I cannot help with that.")

      reranked = described_class.new(query: "q", result: result_of(candidates)).call

      expect(reranked.chunks.map(&:id)).to eq(%w[a b c])
    end

    it "falls back to the fused order when every index is out of range" do
      allow(LlmClient).to receive(:stream_chat).and_return("[9, 12]")

      reranked = described_class.new(query: "q", result: result_of(candidates)).call

      expect(reranked.chunks.map(&:id)).to eq(%w[a b c])
    end

    it "carries abstention and top_similarity through untouched" do
      allow(LlmClient).to receive(:stream_chat).and_return("[2,1,0]")

      reranked = described_class.new(query: "q", result: result_of(candidates, top_similarity: 0.42)).call

      expect(reranked.abstained?).to be(false)
      expect(reranked.top_similarity).to eq(0.42)
    end

    it "does not call the model on an abstained result" do
      allow(LlmClient).to receive(:stream_chat)

      reranked = described_class.new(query: "q", result: result_of([], abstained: true, top_similarity: 0.1)).call

      expect(LlmClient).not_to have_received(:stream_chat)
      expect(reranked.abstained?).to be(true)
      expect(reranked.chunks).to be_empty
    end

    it "does not call the model when there is nothing to reorder (<= 1 candidate)" do
      allow(LlmClient).to receive(:stream_chat)

      single = result_of([ [ chunk("a", "alpha"), 0.9 ] ])
      reranked = described_class.new(query: "q", result: single).call

      expect(LlmClient).not_to have_received(:stream_chat)
      expect(reranked.chunks.map(&:id)).to eq(%w[a])
    end
  end

  describe ".enabled?" do
    it "is off by default" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("RERANK", "false").and_return("false")

      expect(described_class.enabled?).to be(false)
    end

    it "is on when RERANK=true" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("RERANK", "false").and_return("true")

      expect(described_class.enabled?).to be(true)
    end
  end
end
