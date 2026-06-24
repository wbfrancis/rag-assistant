FactoryBot.define do
  factory :document do
    association :tenant, factory: :user
    title { "Test Document" }
    content_type { "text/markdown" }
    source_uri { "paste" }
    raw_text { "# Heading\n\nFirst paragraph of the document.\n\nSecond paragraph with a little more content to chunk." }
    status { :pending }
  end
end
