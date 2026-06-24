require "rails_helper"

# All examples run against the deterministic, offline FakeLlmClient: identical
# text embeds to an identical vector (cosine similarity 1.0) and unrelated text
# is ~orthogonal (~0). That is what makes both the above-floor and below-floor
# paths reproducible without a network (§11).
RSpec.describe Retriever do
  let(:fake) { FakeLlmClient.new }

  before { LlmClient.backend = fake }

  # Seed one embedded chunk for +user+ whose stored vector is the Fake's vector
  # for +content+, so a query equal to +content+ is a guaranteed top hit.
  def seed_chunk(user, content, document: create(:document, tenant: user), **attrs)
    create(:chunk, :embedded, document: document, content: content, **attrs)
  end

  describe "ranking" do
    it "ranks an exact-content match first, ordered by similarity descending" do
      user = create(:user)
      doc = create(:document, tenant: user)
      exact = seed_chunk(user, "needle in the haystack", document: doc, position: 0)
      seed_chunk(user, "first unrelated distractor", document: doc, position: 1)
      seed_chunk(user, "second unrelated distractor", document: doc, position: 2)

      # Drop the floor so the distractors are returned too and we can assert order.
      result = Retriever.new(tenant: user, query: "needle in the haystack", min_similarity: -1.0).call

      similarities = result.scored.map(&:last)
      expect(similarities).to eq(similarities.sort.reverse)
      expect(result.chunks.first).to eq(exact)
      expect(result.top_similarity).to be_within(0.0001).of(1.0)
    end

    it "caps the number of results at k" do
      user = create(:user)
      doc = create(:document, tenant: user)
      3.times { |i| seed_chunk(user, "corpus chunk #{i}", document: doc, position: i) }

      result = Retriever.new(tenant: user, query: "corpus chunk 0", k: 2, min_similarity: -1.0).call

      expect(result.chunks.size).to eq(2)
    end
  end

  describe "relevance floor" do
    it "abstains when nothing clears the floor" do
      user = create(:user)
      seed_chunk(user, "alpha beta gamma")

      result = Retriever.new(tenant: user, query: "totally different unrelated phrase").call

      expect(result.abstained?).to be(true)
      expect(result.chunks).to be_empty
    end

    it "does not abstain when a chunk clears the floor" do
      user = create(:user)
      seed_chunk(user, "matching content here")

      result = Retriever.new(tenant: user, query: "matching content here").call

      expect(result.abstained?).to be(false)
      expect(result.chunks.size).to eq(1)
      expect(result.top_similarity).to be_within(0.0001).of(1.0)
    end
  end

  describe "tenant isolation (security regression)" do
    it "never returns another tenant's chunks, even with identical content" do
      a = create(:user)
      b = create(:user)
      seed_chunk(a, "shared secret content")
      b_chunk = seed_chunk(b, "shared secret content")

      result = Retriever.new(tenant: a, query: "shared secret content").call

      # A failure here is a security bug, not a relevance miss.
      expect(result.chunks).not_to include(b_chunk)
      expect(result.chunks.map(&:tenant_id)).to all(eq(a.id))
    end
  end

  describe "embedding_model filter" do
    it "excludes chunks stamped with a different embedding_model" do
      user = create(:user)
      seed_chunk(user, "matching content", embedding_model: "some-old-model")

      result = Retriever.new(tenant: user, query: "matching content").call

      expect(result.chunks).to be_empty
      expect(result.abstained?).to be(true)
    end
  end

  describe "null-embedding exclusion" do
    it "never returns a chunk still missing its vector" do
      user = create(:user)
      doc = create(:document, tenant: user)
      create(:chunk, document: doc, content: "pending content", embedding: nil)

      result = Retriever.new(tenant: user, query: "pending content").call

      expect(result.chunks).to be_empty
    end
  end

  describe "model parity" do
    it "embeds the query with the active ingestion embedding model" do
      user = create(:user)
      seed_chunk(user, "parity content")

      Retriever.new(tenant: user, query: "parity content").call

      expect(fake.models_used).to include(LlmClient.config.embedding_model)
    end
  end

  describe "blank query" do
    it "returns an empty, non-abstaining result without calling the LLM" do
      user = create(:user)

      result = Retriever.new(tenant: user, query: "   ").call

      expect(result.chunks).to be_empty
      expect(result.abstained?).to be(false)
      expect(fake.embed_calls).to eq(0)
    end
  end
end
