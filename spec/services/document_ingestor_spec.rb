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
end
