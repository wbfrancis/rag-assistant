require "rails_helper"

RSpec.describe GenerateAnswerJob do
  before { LlmClient.backend = FakeLlmClient.new }

  def seed_conversation
    user = create(:user)
    conversation = create(:conversation, tenant: user)
    doc = create(:document, tenant: user)
    chunk = create(:chunk, :embedded, document: doc, content: "the answer is forty two",
                                       content_hash: "h1", token_count: 5)
    user_message = create(:message, conversation: conversation, role: :user, content: "the answer is forty two")
    assistant = create(:message, :assistant, conversation: conversation, content: "")
    [ conversation, user_message, assistant, chunk ]
  end

  it "generates a grounded answer and persists it onto the assistant message" do
    conversation, user_message, assistant, chunk = seed_conversation

    described_class.perform_now(user_message_id: user_message.id, assistant_message_id: assistant.id)

    assistant.reload
    expect(assistant.content).to eq(FakeLlmClient::CANNED_TOKENS.join)
    expect(assistant.chunk_ids).to eq([ chunk.id ])
    expect(assistant.model).to eq(LlmClient.config.chat_model)
  end

  it "broadcasts streamed tokens to the conversation's Turbo Stream" do
    conversation, user_message, assistant, _chunk = seed_conversation

    # Turbo broadcasts to the conversation's signed gid stream (what
    # `turbo_stream_from @conversation` in the view subscribes to).
    expect do
      described_class.perform_now(user_message_id: user_message.id, assistant_message_id: assistant.id)
    end.to have_broadcasted_to(conversation.to_gid_param).at_least(:once)
  end

  it "abstains (no fabrication) when nothing clears the relevance floor" do
    user = create(:user)
    conversation = create(:conversation, tenant: user)
    doc = create(:document, tenant: user)
    create(:chunk, :embedded, document: doc, content: "completely unrelated corpus text", token_count: 5)
    user_message = create(:message, conversation: conversation, role: :user, content: "an utterly different question")
    assistant = create(:message, :assistant, conversation: conversation, content: "")

    described_class.perform_now(user_message_id: user_message.id, assistant_message_id: assistant.id)

    assistant.reload
    expect(assistant.content).to eq(AnswerGenerator::ABSTAIN_MESSAGE)
    expect(assistant.chunk_ids).to be_empty
  end
end
