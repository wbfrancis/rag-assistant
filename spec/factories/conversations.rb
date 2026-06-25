FactoryBot.define do
  factory :conversation do
    association :tenant, factory: :user
    title { "A conversation" }
  end
end
