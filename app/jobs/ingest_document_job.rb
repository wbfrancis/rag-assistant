class IngestDocumentJob < ApplicationJob
  queue_as :default

  # Retry transient LLM failures with backoff; give up if the document is gone.
  retry_on LlmClient::RateLimitError, LlmClient::TimeoutError,
           wait: :polynomially_longer, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  def perform(document_id)
    document = Document.find(document_id)
    DocumentIngestor.new(document).call
  end
end
