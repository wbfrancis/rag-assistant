FactoryBot.define do
  factory :message do
    conversation
    role { :user }
    content { "What does the document say?" }

    # An assistant answer: blank until streamed, then filled with content +
    # grounding metadata.
    trait :assistant do
      role { :assistant }
      content { "The document says hello." }
      model { "gpt-4o-mini" }
      chunk_ids { [] }
      citations { [] }
    end
  end
end
