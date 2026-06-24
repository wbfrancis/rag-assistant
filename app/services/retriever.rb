# frozen_string_literal: true

# Retriever is the online query side's first half (RAG_ASSISTANT_ARCHITECTURE.md
# §5): given a tenant and a natural-language query, embed the query with the
# *same* model used at ingestion and return the tenant's nearest chunks by cosine
# similarity, ranked, capped at +k+, and gated behind a relevance floor.
#
# The security core is the tenant pre-filter (§4 / §10): every search chains off
# +Chunk.for_tenant+, so vector search and tenant isolation compose into a single
# SQL query and a user can never reach another tenant's rows. The denormalized
# +tenant_id+ on +chunks+ is what makes that pre-filter cheap (ADR 0002).
#
# When nothing clears the floor the Retriever *abstains* rather than handing weak
# context to the LLM downstream — the system declines at retrieval, not by
# trusting the model to (§5 relevance floor, §10 hallucination guardrail).
#
# Single-query only: multi-turn query contextualization arrives in Phase 3. See
# docs/adr/0003-retrieval.md.
class Retriever
  # Cosine-similarity floor below which the top hit is treated as "no relevant
  # context" and the search abstains. 0.30 is a realistic threshold for
  # text-embedding-3-small (relevant chunks often score ~0.3–0.5); a higher floor
  # would abstain on nearly everything. Single source of truth — overridable per
  # call via +min_similarity:+ so the Phase 4 eval harness can sweep it.
  RELEVANCE_FLOOR = 0.30

  # The outcome of a search. +scored+ is an ordered (similarity desc) array of
  # +[chunk, similarity]+ pairs; +chunks+ is just the chunks. +abstained?+ is
  # true when a query *ran* but nothing cleared the floor (distinct from a blank
  # query, which yields an empty, non-abstaining result). +top_similarity+ is the
  # best similarity seen even when abstaining, so the eval harness can inspect it.
  Result = Struct.new(:scored, :abstained, :top_similarity, keyword_init: true) do
    def chunks
      scored.map(&:first)
    end

    def abstained?
      abstained
    end
  end

  def initialize(tenant:, query:, k: 8, min_similarity: RELEVANCE_FLOOR)
    @tenant = tenant
    @query = query.to_s
    @k = k
    @min_similarity = min_similarity
  end

  def call
    # Blank query: nothing to search, and crucially no embedding call. This is an
    # empty result, not an abstention — we never asked the corpus a question.
    return empty_result if @query.strip.empty?

    query_vector = LlmClient.embed(@query).first

    scored = neighbors(query_vector).map { |chunk| [ chunk, similarity_for(chunk) ] }
    top = scored.first&.last # neighbors come back nearest-first => highest sim first

    if top.nil? || top < @min_similarity
      Result.new(scored: [], abstained: true, top_similarity: top)
    else
      kept = scored.select { |_chunk, similarity| similarity >= @min_similarity }
      Result.new(scored: kept, abstained: false, top_similarity: top)
    end
  end

  private

  # The non-negotiable security core. +for_tenant+ comes first so tenant
  # isolation and the kNN search compose into one SQL query (cheap because
  # +tenant_id+ is denormalized onto chunks — §4 / ADR 0002). The
  # +embedding_model+ filter keeps mixed-model vectors out of results during a
  # future rolling re-index, and +where.not(embedding: nil)+ skips chunks still
  # mid-ingestion. Cosine distance matches the HNSW +vector_cosine_ops+ index.
  def neighbors(query_vector)
    Chunk.for_tenant(@tenant)
         .where(embedding_model: LlmClient.config.embedding_model)
         .where.not(embedding: nil)
         .nearest_neighbors(:embedding, query_vector, distance: "cosine")
         .limit(@k)
  end

  # neighbor returns cosine *distance*; similarity is its complement.
  def similarity_for(chunk)
    1.0 - chunk.neighbor_distance
  end

  def empty_result
    Result.new(scored: [], abstained: false, top_similarity: nil)
  end
end
