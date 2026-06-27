# frozen_string_literal: true

# Retriever is the online query side's first half (RAG_ASSISTANT_ARCHITECTURE.md
# §5): given a tenant and a natural-language query, return the tenant's most
# relevant chunks, ranked, capped at +k+, and gated behind a relevance floor.
#
# Retrieval is **hybrid** (ADR 0007): a *dense* leg (pgvector cosine kNN over the
# query embedding) and a *lexical* leg (Postgres full-text search over a generated
# +content_tsv+) each fetch a wider candidate pool, and the two ranked lists are
# fused with Reciprocal Rank Fusion. The dense leg finds semantic matches; the
# lexical leg catches exact tokens dense embeddings blur — names, codes, acronyms,
# rare IDs. Hybrid is toggleable (+hybrid:+, default on) so the eval harness can
# run hybrid-vs-dense head to head; with it off the Retriever is the pure dense
# kNN of ADR 0003.
#
# The security core is the tenant pre-filter (§4 / §10): *both* legs chain off
# +Chunk.for_tenant+, so vector search, lexical search and tenant isolation each
# compose into a single SQL query and a user can never reach another tenant's
# rows. The denormalized +tenant_id+ on +chunks+ is what makes that pre-filter
# cheap (ADR 0002).
#
# Abstention is preserved unchanged across the fusion (ADR 0003 / 0007): the
# relevance floor still keys off the *dense* top similarity, so the system
# declines on semantically out-of-domain queries even though RRF may reorder which
# chunk lands first. When nothing clears the floor the Retriever abstains rather
# than handing weak context to the LLM downstream.
#
# The Retriever expects an already-standalone query: for multi-turn chat,
# +GenerateAnswerJob+ runs +QueryContextualizer+ to condense the history + new
# question into a standalone query before handing it here. Each search emits one
# structured log line (scores + timings + mode, no content) via +RetrievalLogger+
# for debuggability (§10). See docs/adr/0003-retrieval.md and 0007-hybrid-search.md.
class Retriever
  # Cosine-similarity floor below which the top hit is treated as "no relevant
  # context" and the search abstains. 0.30 is a realistic threshold for
  # text-embedding-3-small (relevant chunks often score ~0.3–0.5); a higher floor
  # would abstain on nearly everything. Single source of truth — overridable per
  # call via +min_similarity:+ so the Phase 4 eval harness can sweep it.
  RELEVANCE_FLOOR = 0.30

  # Default number of chunks a search returns.
  DEFAULT_K = 8

  # How many candidates *each* leg fetches before fusion. Wider than +k+ so a
  # chunk the dense leg ranks low (but the lexical leg ranks high, or vice versa)
  # can still surface in the fused top-+k+. Also the pool an optional LLM re-rank
  # (ADR 0008) reorders.
  DEFAULT_CANDIDATE_K = 20

  # Reciprocal Rank Fusion constant. score(chunk) = Σ 1 / (RRF_K + rank) over the
  # lists the chunk appears in. 60 is the value from the original RRF paper
  # (Cormack et al., 2009); large enough that rank differences past the top few
  # matter little, small enough that the very top ranks still dominate. RRF fuses
  # the two legs *by rank*, so it never has to normalize cosine similarity against
  # ts_rank — two scores on entirely different scales (ADR 0007).
  RRF_K = 60

  # The lexical-leg tsquery. We deliberately turn plainto_tsquery's AND into an
  # OR: plainto ANDs every lexeme, so a single query word absent from a chunk
  # (e.g. "hardware") rejects an otherwise strong lexical match. Rewriting ' & '
  # to ' | ' on plainto's already-normalised, already-quoted output (so
  # hyphenated tokens like "e-4421" stay valid) gives match-on-any-term recall,
  # and ts_rank then rewards chunks matching *more* terms. The `?` is a bound
  # placeholder (no interpolation of user input), so the lexical leg is
  # injection-safe; +id+ in the sort is a deterministic tie-break.
  TSQUERY       = "replace(plainto_tsquery('english', ?)::text, ' & ', ' | ')::tsquery"
  LEXICAL_MATCH = "content_tsv @@ #{TSQUERY}"
  LEXICAL_RANK  = "ts_rank(content_tsv, #{TSQUERY}) DESC, id"

  # The outcome of a search. +scored+ is an ordered array of +[chunk, similarity]+
  # pairs — fused (RRF) order in hybrid mode, cosine-descending in dense mode.
  # +similarity+ is the chunk's *dense* cosine similarity, or +nil+ for a chunk
  # that only the lexical leg surfaced (it has no comparable cosine score).
  # +chunks+ is just the chunks. +abstained?+ is true when a query *ran* but
  # nothing cleared the floor (distinct from a blank query, which yields an empty,
  # non-abstaining result). +top_similarity+ is the best *dense* similarity seen
  # even when abstaining, so the eval harness can inspect it.
  Result = Struct.new(:scored, :abstained, :top_similarity, keyword_init: true) do
    def chunks
      scored.map(&:first)
    end

    def abstained?
      abstained
    end
  end

  def initialize(tenant:, query:, k: DEFAULT_K, min_similarity: RELEVANCE_FLOOR,
                 hybrid: true, candidate_k: DEFAULT_CANDIDATE_K)
    @tenant = tenant
    @query = query.to_s
    @k = k
    @min_similarity = min_similarity
    @hybrid = hybrid
    @candidate_k = [ candidate_k, k ].max
  end

  def call
    # Blank query: nothing to search, and crucially no embedding call. This is an
    # empty result, not an abstention — we never asked the corpus a question.
    return empty_result if @query.strip.empty?

    embed_started = monotonic
    query_vector  = LlmClient.embed(@query).first
    embedding_ms  = elapsed_ms(embed_started)

    dense_started = monotonic
    dense   = dense_leg(query_vector)
    dense_ms = elapsed_ms(dense_started)
    # Abstention keys off dense semantic similarity (ADR 0003 preserved): the
    # nearest neighbour is first, so its similarity is the best the corpus offers.
    top = dense.first&.last

    lexical_ms = nil
    scored =
      if @hybrid
        lexical_started = monotonic
        lexical = lexical_leg
        lexical_ms = elapsed_ms(lexical_started)
        fuse(dense, lexical)
      else
        dense
      end

    result = build_result(top: top, scored: scored)

    RetrievalLogger.log_retrieval(
      tenant: @tenant, query: @query, k: @k, result: result, mode: mode,
      embedding_ms: embedding_ms, dense_ms: dense_ms, lexical_ms: lexical_ms
    )
    result
  end

  # Reciprocal Rank Fusion over any number of ranked chunk lists. A pure function
  # of the lists' *order* (not their scores), extracted as a class method so the
  # RRF math is unit-testable in isolation. Ties break on +id+ so a fused ordering
  # is fully deterministic — which the eval harness depends on.
  def self.reciprocal_rank_fusion(ranked_lists, limit:, rrf_k: RRF_K)
    scores       = Hash.new(0.0)
    chunk_by_id  = {}

    ranked_lists.each do |list|
      list.each_with_index do |chunk, index|
        scores[chunk.id] += 1.0 / (rrf_k + index + 1)
        chunk_by_id[chunk.id] ||= chunk
      end
    end

    scores
      .sort_by { |id, score| [ -score, id ] }
      .first(limit)
      .map { |id, _score| chunk_by_id[id] }
  end

  private

  def mode
    @hybrid ? "hybrid" : "dense"
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started)
    ((monotonic - started) * 1000).round
  end

  # Apply the relevance floor. Abstain when the best *dense* hit is below it
  # (or there is none). Otherwise keep the results — in hybrid mode that's the
  # whole fused top-k (a lexically-strong, cosine-weak chunk is exactly what
  # hybrid exists to surface, so it is *not* floor-filtered); in dense mode we
  # additionally drop any individual chunk under the floor, as ADR 0003 did.
  def build_result(top:, scored:)
    if top.nil? || top < @min_similarity
      Result.new(scored: [], abstained: true, top_similarity: top)
    else
      kept = @hybrid ? scored : scored.select { |_chunk, similarity| similarity >= @min_similarity }
      Result.new(scored: kept, abstained: false, top_similarity: top)
    end
  end

  # Dense leg: cosine kNN over the query embedding. Returns +[chunk, similarity]+
  # pairs, nearest first. Pulls the wider candidate pool in hybrid mode (so fusion
  # has material to work with) and exactly +k+ in dense mode (ADR 0003 behaviour).
  def dense_leg(query_vector)
    neighbors(query_vector, @hybrid ? @candidate_k : @k)
      .map { |chunk| [ chunk, similarity_for(chunk) ] }
  end

  # The non-negotiable security core. +for_tenant+ comes first so tenant
  # isolation and the kNN search compose into one SQL query (cheap because
  # +tenant_id+ is denormalized onto chunks — §4 / ADR 0002). The
  # +embedding_model+ filter keeps mixed-model vectors out of results during a
  # rolling re-index, and +where.not(embedding: nil)+ skips chunks still
  # mid-ingestion. Cosine distance matches the HNSW +vector_cosine_ops+ index.
  def neighbors(query_vector, limit)
    Chunk.for_tenant(@tenant)
         .where(embedding_model: LlmClient.config.embedding_model)
         .where.not(embedding: nil)
         .nearest_neighbors(:embedding, query_vector, distance: "cosine")
         .limit(limit)
  end

  # Lexical leg: Postgres full-text search over the generated +content_tsv+,
  # ranked by +ts_rank+. Reuses the *exact* same security/scoping chain as the
  # dense leg (+for_tenant+, +embedding_model+, non-null embedding) so tenant
  # isolation can never drift between the two paths. The WHERE is a bound
  # parameter; the ORDER BY embeds the same query via sanitize_sql_array (order
  # can't take binds). Returns chunks, best-ranked first. See +TSQUERY+ for why
  # the query is OR-of-lexemes, not plainto's AND.
  def lexical_leg
    Chunk.for_tenant(@tenant)
         .where(embedding_model: LlmClient.config.embedding_model)
         .where.not(embedding: nil)
         .where(LEXICAL_MATCH, @query)
         .order(Arel.sql(Chunk.sanitize_sql_array([ LEXICAL_RANK, @query ])))
         .limit(@candidate_k)
         .to_a
  end

  # Fuse the dense and lexical rankings with RRF and re-attach each surviving
  # chunk's dense similarity (nil for a lexical-only hit), preserving the
  # +[chunk, similarity]+ shape every downstream consumer expects.
  def fuse(dense, lexical)
    similarity_by_id = dense.to_h { |chunk, similarity| [ chunk.id, similarity ] }
    ranked = self.class.reciprocal_rank_fusion([ dense.map(&:first), lexical ], limit: @k)
    ranked.map { |chunk| [ chunk, similarity_by_id[chunk.id] ] }
  end

  # neighbor returns cosine *distance*; similarity is its complement.
  def similarity_for(chunk)
    1.0 - chunk.neighbor_distance
  end

  def empty_result
    Result.new(scored: [], abstained: false, top_similarity: nil)
  end
end
