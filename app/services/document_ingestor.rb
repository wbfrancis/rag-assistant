require "digest"

# Orchestrates one document's ingestion: extract -> chunk -> reconcile -> embed.
#
# Reconciliation is a per-chunk diff keyed on +content_hash+ (see
# docs/adr/0001-chunking-strategy.md): chunks whose content is unchanged keep
# their existing row (and their already-computed embedding), new chunks are
# inserted with a NULL embedding, and chunks no longer produced are deleted.
#
# Embedding is *resumable*: chunks are persisted before embedding, and only
# chunks still missing a vector are embedded, each saved as its vector returns.
# So a run that dies (or hits a rate limit) part-way through can be retried and
# will only re-embed the chunks that never got a vector.
class DocumentIngestor
  def initialize(document)
    @document = document
  end

  def call
    @document.update!(status: :processing, error_message: nil)

    text = TextExtractor.call(content_type: @document.content_type, data: source_bytes)
    content_hash = Digest::SHA256.hexdigest(text)

    # Fast path: content unchanged and every chunk already embedded.
    if @document.content_hash == content_hash && @document.chunks.exists? &&
       !@document.chunks.where(embedding: nil).exists?
      @document.update!(status: :processed, processed_at: Time.current)
      return @document
    end

    specs = Chunker.call(text)
    raise TextExtractor::LowYieldError, "Chunker produced no chunks." if specs.empty?

    reconcile(specs)
    embed_missing

    @document.update!(status: :processed, processed_at: Time.current, content_hash: content_hash)
    @document
  rescue TextExtractor::Error => e
    # Permanent extraction problems: fail loudly with a clear message.
    @document.update!(status: :failed, error_message: e.message)
    @document
  end

  private

  # Uploaded files live in Active Storage; pasted text lives in raw_text.
  def source_bytes
    @document.file.attached? ? @document.file.download : @document.raw_text
  end

  # Diff the desired chunk specs against the persisted chunks, matching on
  # +content_hash+. Survivors are repositioned in place (keeping their
  # embedding); brand-new chunks are inserted with a NULL embedding; everything
  # left over is deleted. Runs in one transaction so the chunk set is never
  # observed half-reconciled.
  def reconcile(specs)
    pool = Hash.new { |h, k| h[k] = [] }
    # Read existing chunks through a standalone scope (not @document.chunks) so we
    # never populate the association cache with rows that embed_missing later
    # updates out-of-band -- the caller's @document.chunks would otherwise go stale.
    Chunk.where(document_id: @document.id).find_each { |chunk| pool[chunk.content_hash] << chunk }

    ActiveRecord::Base.transaction do
      specs.each do |spec|
        if (chunk = pool[spec[:content_hash]].shift)
          chunk.update!(
            position: spec[:position],
            token_count: spec[:token_count],
            metadata: spec[:metadata]
          )
        else
          @document.chunks.create!(
            tenant_id: @document.tenant_id,
            position: spec[:position],
            content: spec[:content],
            content_hash: spec[:content_hash],
            token_count: spec[:token_count],
            embedding: nil,
            metadata: spec[:metadata]
          )
        end
      end

      stale_ids = pool.values.flatten.map(&:id)
      @document.chunks.where(id: stale_ids).delete_all if stale_ids.any?
    end
  end

  # Embed only chunks that still lack a vector, persisting each as it returns so
  # a retry resumes from where a previous run left off. Embedding errors
  # (rate limit, timeout) propagate to the job for retry/backoff.
  def embed_missing
    pending = @document.chunks.where(embedding: nil).order(:position).to_a
    return if pending.empty?

    vectors = LlmClient.embed(pending.map(&:content))

    pending.each_with_index do |chunk, i|
      chunk.update!(
        embedding: vectors[i],
        embedding_model: LlmClient.config.embedding_model,
        embedding_dim: LlmClient.config.embedding_dim
      )
    end
  end
end
