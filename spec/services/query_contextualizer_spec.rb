require "rails_helper"

RSpec.describe QueryContextualizer do
  let(:fake) { FakeLlmClient.new }

  before { LlmClient.backend = fake }

  it "passes the question through unchanged on the first turn, with no LLM call" do
    conversation = create(:conversation)

    result = described_class.new(conversation: conversation, question: "What is RAG?").call

    expect(result).to eq("What is RAG?")
    expect(fake.chat_calls).to eq(0)
  end

  it "rewrites a follow-up using prior turns (one chat call)" do
    conversation = create(:conversation)
    create(:message, conversation: conversation, role: :user, content: "Tell me about pgvector.")
    create(:message, :assistant, conversation: conversation, content: "It is a Postgres extension.")

    result = described_class.new(conversation: conversation, question: "What are its limits?").call

    # The Fake returns its canned join for any chat; the point is a rewrite happened.
    expect(result).to eq(FakeLlmClient::CANNED_TOKENS.join)
    expect(fake.chat_calls).to eq(1)
  end

  it "falls back to the raw question when the model returns nothing" do
    LlmClient.backend = FakeLlmClient.new(chat_tokens: [])
    conversation = create(:conversation)
    create(:message, conversation: conversation, role: :user, content: "Earlier question.")

    result = described_class.new(conversation: conversation, question: "And after that?").call

    expect(result).to eq("And after that?")
  end
end
