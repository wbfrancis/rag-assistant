require "rails_helper"

RSpec.describe IngestDocumentJob, type: :job do
  before { LlmClient.backend = FakeLlmClient.new }

  it "ingests the document via DocumentIngestor" do
    document = create(:document)

    IngestDocumentJob.perform_now(document.id)

    expect(document.reload).to be_processed
    expect(document.chunks.count).to be >= 1
  end

  it "discards the job if the document no longer exists" do
    expect { IngestDocumentJob.perform_now(SecureRandom.uuid) }.not_to raise_error
  end
end
