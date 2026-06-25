require "rails_helper"

RSpec.describe "Messages", type: :request do
  include ActiveJob::TestHelper

  before { LlmClient.backend = FakeLlmClient.new }

  describe "POST /conversations/:id/messages" do
    it "records the question, creates an assistant placeholder, and enqueues generation" do
      user = create(:user)
      conversation = create(:conversation, tenant: user, title: nil)
      sign_in(user)

      expect do
        post conversation_messages_path(conversation),
             params: { message: { content: "What is in my docs?" } },
             as: :turbo_stream
      end.to have_enqueued_job(GenerateAnswerJob)

      expect(conversation.messages.user.last.content).to eq("What is in my docs?")
      expect(conversation.messages.assistant.last).to be_present
      expect(conversation.reload.title).to eq("What is in my docs?") # derived from first question
      expect(response).to have_http_status(:ok)
    end

    it "rejects a blank question without enqueuing a job" do
      user = create(:user)
      conversation = create(:conversation, tenant: user)
      sign_in(user)

      expect do
        post conversation_messages_path(conversation), params: { message: { content: "  " } }
      end.not_to have_enqueued_job(GenerateAnswerJob)

      expect(response).to redirect_to(conversation)
    end
  end

  describe "tenant isolation" do
    it "404s when posting into another tenant's conversation" do
      owner = create(:user)
      other = create(:conversation, tenant: create(:user))
      sign_in(owner)

      post conversation_messages_path(other), params: { message: { content: "sneaky" } }

      expect(response).to have_http_status(:not_found)
    end
  end
end
