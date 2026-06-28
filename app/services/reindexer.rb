# frozen_string_literal: true

# Rolling embedding-model re-index (ADR 0006).
#
# Every chunk records the embedding_model that produced its vector, so changing
# models doesn't require a blind wipe: this re-embeds, in batches, only the
# chunks not already at the target model, stamping each with the new model/dim
# as its vector returns. It is therefore:
#   * idempotent — chunks already at target_model are skipped, so re-running
#     after a completed pass is a no-op;
#   * resumable  — each chunk is saved as it is embedded, so an interrupted run
#     (rate limit, crash) picks up where it left off.
#
# The Retriever filters to LlmClient.config.embedding_model, so that config value
# *is* the cutover switch: backfill the new model, validate it on `rake eval`,
# then point the config at it (ADR 0006). A dimension change also needs a
# vector(N) column + HNSW index migration — guarded against here so we fail
# loudly instead of corrupting the column rather than silently breaking it.
class Reindexer
  DEFAULT_BATCH_SIZE = 100

  # Raised when the target model's vectors don't fit the existing column width.
  class DimensionMismatchError < StandardError; end

  def initialize(target_model: LlmClient.config.embedding_model,
                 target_dim: LlmClient.config.embedding_dim,
                 batch_size: DEFAULT_BATCH_SIZE,
                 logger: Rails.logger)
    @target_model = target_model
    @target_dim = target_dim
    @batch_size = batch_size
    @logger = logger
  end

  # Chunk counts grouped by embedding_model (nil key = never embedded), so you
  # can watch a migration progress and confirm it finished.
  def status
    Chunk.group(:embedding_model).count
  end

  # Re-embed every chunk not already at target_model. Returns the count
  # re-embedded.
  def backfill
    total = 0

    pending_scope.find_in_batches(batch_size: @batch_size) do |batch|
      vectors = LlmClient.embed(batch.map(&:content), model: @target_model)
      guard_dimension!(vectors.first)

      batch.each_with_index do |chunk, i|
        chunk.update!(embedding: vectors[i], embedding_model: @target_model, embedding_dim: @target_dim)
      end

      total += batch.size
      @logger.info({ event: "reindex_batch", target_model: @target_model, reindexed: total }.to_json)
    end

    total
  end

  private

  # Everything not at the target model, including chunks never embedded (NULL
  # embedding_model, which a bare where.not would exclude).
  def pending_scope
    Chunk.where.not(embedding_model: @target_model).or(Chunk.where(embedding_model: nil))
  end

  # A model whose vectors don't match the column width can't be written in place;
  # that needs a schema migration, not just re-embedding (ADR 0006). Fail loudly.
  def guard_dimension!(vector)
    return if vector.nil? || vector.length == @target_dim

    raise DimensionMismatchError,
      "Target model produced #{vector.length}-dim vectors but the column/target_dim is #{@target_dim}. " \
      "A dimension change needs a vector(N) column + HNSW index migration before backfilling (ADR 0006)."
  end
end
