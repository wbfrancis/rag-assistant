require "rails_helper"

# Runs against the deterministic FakeLlmClient (no network): every backfill
# re-embeds through the same adapter the real pipeline uses.
RSpec.describe Reindexer do
  let(:fake)   { FakeLlmClient.new }
  let(:target) { LlmClient.config.embedding_model } # "text-embedding-3-small"

  before { LlmClient.backend = fake }

  def chunk_with(model:, embedding: Array.new(1536) { 0.001 })
    create(:chunk, embedding_model: model, embedding: embedding)
  end

  describe "#backfill" do
    it "re-embeds chunks not already at the target model and stamps model/dim" do
      stale = chunk_with(model: "old-model")

      count = described_class.new(target_model: target).backfill

      expect(count).to eq(1)
      expect(fake.embed_calls).to be >= 1
      stale.reload
      expect(stale.embedding_model).to eq(target)
      expect(stale.embedding_dim).to eq(LlmClient.config.embedding_dim)
      expect(stale.embedding).to be_present
    end

    it "embeds chunks that were never embedded (nil embedding_model)" do
      never = chunk_with(model: nil, embedding: nil)

      described_class.new(target_model: target).backfill

      never.reload
      expect(never.embedding_model).to eq(target)
      expect(never.embedding).to be_present
    end

    it "skips chunks already at the target model (idempotent)" do
      chunk_with(model: target)
      expect(described_class.new(target_model: target).backfill).to eq(0)
    end

    it "is a no-op on a second run after a completed pass" do
      chunk_with(model: "old-model")
      reindexer = described_class.new(target_model: target)

      reindexer.backfill
      expect(reindexer.backfill).to eq(0)
    end

    it "fails loudly on a dimension change instead of writing a mis-sized vector" do
      stale = chunk_with(model: "old-model")
      # The Fake outputs 1536-dim vectors; a target_dim of 3072 must not be written.
      reindexer = described_class.new(target_model: target, target_dim: 3072)

      expect { reindexer.backfill }.to raise_error(Reindexer::DimensionMismatchError)
      expect(stale.reload.embedding_model).to eq("old-model") # untouched
    end
  end

  describe "#status" do
    it "counts chunks grouped by embedding_model" do
      chunk_with(model: "old-model")
      chunk_with(model: "old-model")
      chunk_with(model: target)

      expect(described_class.new.status).to include("old-model" => 2, target => 1)
    end
  end
end
