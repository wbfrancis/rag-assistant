# frozen_string_literal: true

require "securerandom"

module Eval
  # Materializes a fixture corpus into the database for one eval run: an ephemeral
  # tenant (User) plus a Document per corpus doc, each ingested **synchronously**
  # through the real DocumentIngestor (real Chunker + LlmClient.embed) so the
  # harness measures the actual ingestion pipeline.
  #
  # This is meant to run *inside* Runner's rollback transaction (ADR 0005,
  # decision 2): it deliberately does no cleanup of its own — the transaction
  # rollback is what undoes every row it inserts. Ingestion runs inline rather
  # than via IngestDocumentJob because a background job runs on a different DB
  # connection that cannot see the uncommitted transaction.
  class CorpusSeeder
    def initialize(dataset:)
      @dataset = dataset
    end

    # Creates the tenant + ingested documents and returns the tenant (a User) for
    # the Retriever to scope to.
    def seed
      tenant = build_tenant

      @dataset.corpus.each do |doc|
        document = tenant.documents.create!(
          title: doc.title,
          source_uri: "eval",
          content_type: "text/markdown",
          raw_text: doc.body,
          status: :pending
        )
        DocumentIngestor.new(document).call
      end

      tenant
    end

    private

    def build_tenant
      User.create!(
        email_address: "eval-#{SecureRandom.hex(8)}@local.eval",
        password: SecureRandom.hex(16)
      )
    end
  end
end
