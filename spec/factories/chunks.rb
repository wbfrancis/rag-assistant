FactoryBot.define do
  factory :chunk do
    document
    position { 0 }
    sequence(:content) { |n| "Chunk content number #{n}." }
    token_count { 10 }
    embedding_model { "text-embedding-3-small" }
    embedding_dim { 1536 }
    # Deterministic fake vector of the configured dimension.
    embedding { Array.new(1536) { 0.001 } }
    # tenant_id is copied from the document by Chunk's before_validation.

    # Give the chunk the FakeLlmClient's deterministic vector for its *own*
    # content, so a retrieval query whose text equals this content embeds to the
    # identical vector (cosine similarity 1.0). Lets retrieval specs seed a corpus
    # where "query == content" is a guaranteed top hit and unrelated text is ~0.
    trait :embedded do
      embedding { FakeLlmClient.new.embed(content).first }
    end
  end
end
