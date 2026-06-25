require "rails_helper"

RSpec.describe "Conversations", type: :request do
  before { LlmClient.backend = FakeLlmClient.new }

  describe "authentication" do
    it "redirects anonymous users to sign in" do
      get conversations_path
      expect(response).to redirect_to(new_session_path)
    end
  end

  describe "GET /conversations" do
    it "lists only the current user's conversations" do
      user = create(:user)
      mine = create(:conversation, tenant: user, title: "Mine")
      create(:conversation, tenant: create(:user), title: "Theirs")
      sign_in(user)

      get conversations_path

      expect(response.body).to include("Mine")
      expect(response.body).not_to include("Theirs")
      expect(mine).to be_present
    end
  end

  describe "POST /conversations" do
    it "creates a conversation for the current user and redirects to it" do
      user = create(:user)
      sign_in(user)

      expect { post conversations_path }.to change(user.conversations, :count).by(1)
      expect(response).to redirect_to(Conversation.last)
    end
  end

  describe "tenant isolation" do
    it "404s when showing another tenant's conversation" do
      owner = create(:user)
      other = create(:conversation, tenant: create(:user))
      sign_in(owner)

      get conversation_path(other)

      expect(response).to have_http_status(:not_found)
    end
  end
end
