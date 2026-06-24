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
  end
end
