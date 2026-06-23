require "digest"

# Orchestrates one document's ingestion: extract -> chunk -> embed -> persist.
#
# Thin slice: chunks are replaced wholesale on each run (no per-chunk diff). We
# do keep a document-level short-circuit so re-ingesting unchanged content does
# not re-embed (and re-spend) needlessly.
class DocumentIngestor
  def initialize(document)
    @document = document
  end

  def call
    @document.update!(status: :processing, error_message: nil)

    text = TextExtractor.call(content_type: @document.content_type, data: @document.raw_text)
    content_hash = Digest::SHA256.hexdigest(text)

    if @document.content_hash == content_hash && @document.chunks.exists?
      @document.update!(status: :processed, processed_at: Time.current)
      return @document
    end

    specs = Chunker.call(text)
    raise TextExtractor::LowYieldError, "Chunker produced no chunks." if specs.empty?

    vectors = LlmClient.embed(specs.map { |spec| spec[:content] })

    ActiveRecord::Base.transaction do
      @document.chunks.delete_all
      specs.each_with_index do |spec, i|
        @document.chunks.create!(
          tenant_id: @document.tenant_id,
          position: spec[:position],
          content: spec[:content],
          content_hash: spec[:content_hash],
          token_count: spec[:token_count],
          embedding: vectors[i],
          embedding_model: LlmClient.config.embedding_model,
          embedding_dim: LlmClient.config.embedding_dim,
          metadata: spec[:metadata]
        )
      end
      @document.update!(status: :processed, processed_at: Time.current, content_hash: content_hash)
    end

    @document
  rescue TextExtractor::Error => e
    # Permanent extraction problems: fail loudly with a clear message.
    @document.update!(status: :failed, error_message: e.message)
    @document
  end
end
