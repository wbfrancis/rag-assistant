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

  # Hybrid fuses a dense (cosine) leg with a lexical (full-text) leg. Under the
  # Fake, a chunk whose content equals the query embeds to cosine 1.0 (a strong
  # dense + lexical hit); a chunk that merely shares a *word* with the query is
  # ~orthogonal in dense space (cosine ~0, below the floor) but a real lexical
  # hit — which is exactly the case hybrid exists to rescue.
  describe "hybrid search (dense + lexical fusion)" do
    it "returns a lexically-matched chunk whose cosine similarity is below the floor" do
      user = create(:user)
      doc  = create(:document, tenant: user)
      anchor  = seed_chunk(user, "anchor semantic match phrase", document: doc, position: 0)
      lexical = seed_chunk(user, "anchor unrelated tokens", document: doc, position: 1)

      result = Retriever.new(tenant: user, query: "anchor semantic match phrase", hybrid: true).call

      # The anchor clears the floor (so we don't abstain); the lexical-only chunk
      # rides in on the full-text leg even though its cosine is well below 0.30.
      expect(result.abstained?).to be(false)
      expect(result.chunks).to include(anchor, lexical)
      expect(result.chunks.first).to eq(anchor)
    end

    it "drops that same lexically-matched chunk in dense-only mode (the contrast)" do
      user = create(:user)
      doc  = create(:document, tenant: user)
      anchor  = seed_chunk(user, "anchor semantic match phrase", document: doc, position: 0)
      lexical = seed_chunk(user, "anchor unrelated tokens", document: doc, position: 1)

      result = Retriever.new(tenant: user, query: "anchor semantic match phrase", hybrid: false).call

      # Dense alone floor-filters the cosine-weak chunk out (ADR 0003 behaviour).
      expect(result.chunks).to include(anchor)
      expect(result.chunks).not_to include(lexical)
    end

    it "still abstains on the dense floor even when the lexical leg matches" do
      user = create(:user)
      # Only a lexically-overlapping, semantically-distant chunk exists: dense top
      # is ~0 (< floor), so abstention holds even though full-text would match.
      seed_chunk(user, "anchor unrelated tokens")

      result = Retriever.new(tenant: user, query: "anchor semantic match phrase", hybrid: true).call

      expect(result.abstained?).to be(true)
      expect(result.chunks).to be_empty
    end

    it "records the dense top_similarity even when a lexical hit is in the result" do
      user = create(:user)
      doc  = create(:document, tenant: user)
      seed_chunk(user, "anchor semantic match phrase", document: doc, position: 0)
      seed_chunk(user, "anchor unrelated tokens", document: doc, position: 1)

      result = Retriever.new(tenant: user, query: "anchor semantic match phrase", hybrid: true).call

      expect(result.top_similarity).to be_within(0.0001).of(1.0)
    end
  end

  describe "lexical-leg tenant isolation (security regression)" do
    it "never returns another tenant's chunk via the full-text leg" do
      a = create(:user)
      b = create(:user)
      # a's chunk matches the query semantically (clears the floor, so a doesn't
      # abstain). b's chunk shares the lexemes "zebra"/"code" — it would be a
      # lexical candidate if the full-text leg were not tenant-scoped.
      seed_chunk(a, "public zebra code marker")
      b_chunk = seed_chunk(b, "secret zebra code marker")

      result = Retriever.new(tenant: a, query: "public zebra code marker", hybrid: true).call

      # A failure here is a cross-tenant leak through the lexical path, not a
      # relevance miss.
      expect(result.chunks).not_to include(b_chunk)
      expect(result.chunks.map(&:tenant_id)).to all(eq(a.id))
    end
  end

  # The RRF math, isolated from the DB: a pure function of each list's *order*.
  describe ".reciprocal_rank_fusion" do
    Item = Struct.new(:id)

    it "scores by summed reciprocal rank across lists and returns the top `limit`" do
      a = Item.new("a")
      b = Item.new("b")
      c = Item.new("c")

      # a: rank0 in list1 + rank1 in list2; c: rank2 in list1 + rank0 in list2.
      # a's contributions (1/61 + 1/62) just edge out c's (1/63 + 1/61); b trails.
      fused = Retriever.reciprocal_rank_fusion([ [ a, b, c ], [ c, a ] ], limit: 2)

      expect(fused.map(&:id)).to eq(%w[a c])
    end

    it "breaks ties deterministically by id" do
      x = Item.new("b")
      y = Item.new("a")

      # Each appears once at rank0 → equal score → ascending id wins.
      fused = Retriever.reciprocal_rank_fusion([ [ x ], [ y ] ], limit: 2)

      expect(fused.map(&:id)).to eq(%w[a b])
    end

    it "deduplicates a chunk that appears in both lists" do
      a = Item.new("a")
      b = Item.new("b")

      fused = Retriever.reciprocal_rank_fusion([ [ a, b ], [ a ] ], limit: 10)

      expect(fused.map(&:id)).to eq(%w[a b])
    end
  end
end
