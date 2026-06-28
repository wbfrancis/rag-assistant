require "rails_helper"

# End-to-end happy path for Phase 3:
# sign in → ask a question in a conversation → the answer job retrieves grounded
# context and generates an answer → the rendered conversation shows the answer
# with a citation back to the source document.
#
# Driven through the real HTTP surface + the real GenerateAnswerJob (run inline),
# entirely offline via the deterministic FakeLlmClient — no browser, no network.
# Streaming-over-WebSockets itself is asserted in the job spec; here we verify the
# full ask → generate → cite flow and the persisted, rendered citation.
RSpec.describe "Chat flow", type: :request do
  include ActiveJob::TestHelper

  before { LlmClient.backend = FakeLlmClient.new }

  it "answers a question grounded in the user's document and renders a citation" do
    user = create(:user)
    document = create(:document, tenant: user, title: "Citable Handbook")
    create(:chunk, :embedded, document: document, content: "the capital of France is Paris",
                              content_hash: "c1", token_count: 7)
    sign_in(user)

    # Start a conversation and ask a question that matches the seeded chunk.
    post conversations_path
    conversation = user.conversations.last

    perform_enqueued_jobs do
      post conversation_messages_path(conversation),
           params: { message: { content: "the capital of France is Paris" } },
           as: :turbo_stream
    end

    # The assistant answer is persisted and grounded in the chunk.
    assistant = conversation.messages.assistant.last
    expect(assistant.content).to eq(FakeLlmClient::CANNED_TOKENS.join)
    expect(assistant.chunk_ids).to be_present

    # The rendered conversation shows the answer and a citation link to the source.
    get conversation_path(conversation)
    expect(response.body).to include(FakeLlmClient::CANNED_TOKENS.join)
    expect(response.body).to include("Citable Handbook")
    expect(response.body).to include(document_path(document))
  end

  it "abstains instead of fabricating when the corpus has no relevant chunk" do
    user = create(:user)
    document = create(:document, tenant: user)
    create(:chunk, :embedded, document: document, content: "unrelated background material", token_count: 5)
    sign_in(user)

    post conversations_path
    conversation = user.conversations.last

    perform_enqueued_jobs do
      post conversation_messages_path(conversation),
           params: { message: { content: "what is the airspeed of an unladen swallow" } },
           as: :turbo_stream
    end

    get conversation_path(conversation)
    expect(response.body).to include(AnswerGenerator::ABSTAIN_MESSAGE)
  end
end
