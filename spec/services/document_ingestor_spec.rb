require "rails_helper"

RSpec.describe DocumentIngestor do
  before { LlmClient.backend = FakeLlmClient.new }

  it "extracts, chunks, embeds and marks the document processed" do
    document = create(:document)

    DocumentIngestor.new(document).call
    document.reload

    expect(document).to be_processed
    expect(document.processed_at).to be_present
    expect(document.chunks.count).to be >= 1
    expect(document.content_hash).to be_present
  end

  it "stamps each chunk with the embedding model, dim and tenant" do
    document = create(:document)

    DocumentIngestor.new(document).call

    chunk = document.chunks.first
    expect(chunk.embedding_model).to eq(LlmClient.config.embedding_model)
    expect(chunk.embedding_dim).to eq(1536)
    expect(chunk.embedding).to be_present
    expect(chunk.tenant_id).to eq(document.tenant_id)
  end

  it "is idempotent: re-running unchanged content creates no duplicate chunks" do
    document = create(:document)

    DocumentIngestor.new(document).call
    original_ids = document.chunks.pluck(:id).sort

    expect { DocumentIngestor.new(document.reload).call }
      .not_to change { document.chunks.count }
    expect(document.chunks.pluck(:id).sort).to eq(original_ids)
  end

  it "re-chunks when the content changes" do
    document = create(:document)
    DocumentIngestor.new(document).call

    document.update!(raw_text: "# New\n\nCompletely different content.\n\n" + ("More text. " * 200))
    DocumentIngestor.new(document.reload).call

    expect(document.reload).to be_processed
    expect(document.chunks.count).to be >= 1
  end

  it "marks the document failed with a message on low-yield extraction" do
    document = create(:document, raw_text: "hi")

    DocumentIngestor.new(document).call
    document.reload

    expect(document).to be_failed
    expect(document.error_message).to be_present
    expect(document.chunks).to be_empty
  end

  it "ingests an attached PDF, extracting its text from Active Storage" do
    document = create(:document, content_type: "application/pdf", raw_text: nil, source_uri: "sample.pdf")
    document.file.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/sample.pdf")),
      filename: "sample.pdf",
      content_type: "application/pdf"
    )

    DocumentIngestor.new(document).call
    document.reload

    expect(document).to be_processed
    expect(document.chunks.count).to be >= 1
    expect(document.chunks.first.content).to include("Hello PDF world")
  end

  # Build content that reliably packs into more than one chunk.
  def multi_chunk_text(paras = 8, words = 120)
    (1..paras).map { |i| "Paragraph #{i}. " + ("word#{i} " * words) }.join("\n\n")
  end

  it "reuses unchanged chunks and embeds only new content when text is appended" do
    document = create(:document, raw_text: multi_chunk_text)
    DocumentIngestor.new(document).call
    document.reload
    expect(document.chunks.count).to be > 1

    first_chunk    = document.chunks.order(:position).first
    first_hash     = first_chunk.content_hash
    first_id       = first_chunk.id
    first_content  = first_chunk.content

    document.update!(raw_text: document.raw_text + "\n\nBrand new appended paragraph. " + ("zeta " * 200))

    embedded = []
    recorder = FakeLlmClient.new
    recorder.define_singleton_method(:embed) do |texts, **|
      embedded.concat(Array(texts))
      Array(texts).map { |_| Array.new(LlmClient.config.embedding_dim) { 0.0 } }
    end
    LlmClient.backend = recorder

    DocumentIngestor.new(document.reload).call
    document.reload

    # The leading chunk's content is identical, so its row is reused (same id).
    expect(document.chunks.find_by(content_hash: first_hash).id).to eq(first_id)
    # It was not re-embedded; only genuinely new chunks were.
    expect(embedded).not_to include(first_content)
    expect(embedded.length).to be >= 1
    expect(embedded.length).to be < document.chunks.count
    expect(document.chunks.where(embedding: nil)).to be_empty
  end

  it "resumes embedding, re-embedding only chunks still missing a vector" do
    allow(LlmClient).to receive(:sleep) # skip retry backoff
    document = create(:document, raw_text: multi_chunk_text)

    # First run: embedding always fails. Chunks are persisted (with NULL
    # vectors) but the document is never marked processed.
    LlmClient.backend = FakeLlmClient.new(fail_times: Float::INFINITY)
    expect { DocumentIngestor.new(document).call }.to raise_error(LlmClient::RateLimitError)
    document.reload
    expect(document.chunks.count).to be > 1
    expect(document.chunks.where(embedding: nil).count).to eq(document.chunks.count)
    expect(document).not_to be_processed

    # Simulate a prior partial run that embedded all but the final chunk.
    chunks  = document.chunks.order(:position).to_a
    missing = chunks.last
    chunks[0..-2].each do |c|
      c.update!(embedding: Array.new(1536) { 0.0 }, embedding_model: "x", embedding_dim: 1536)
    end

    embedded = []
    backend  = FakeLlmClient.new
    backend.define_singleton_method(:embed) do |texts, **|
      embedded.concat(Array(texts))
      Array(texts).map { |_| Array.new(LlmClient.config.embedding_dim) { 0.01 } }
    end
    LlmClient.backend = backend

    DocumentIngestor.new(document.reload).call
    document.reload

    expect(embedded).to eq([ missing.content ])
    expect(document.chunks.where(embedding: nil)).to be_empty
    expect(document).to be_processed
  end
end
