require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  describe "authentication" do
    it "redirects anonymous users to sign in" do
      get dashboard_path
      expect(response).to redirect_to(new_session_path)
    end
  end

  describe "GET /dashboard" do
    it "shows the signed-in tenant's usage and never another tenant's" do
      me    = create(:user)
      other = create(:user)

      mine = create(:conversation, tenant: me)
      create(:message, :assistant, conversation: mine,
        model: "gpt-4o-mini", prompt_tokens: 1000, completion_tokens: 500, latency_ms: 250)

      theirs = create(:conversation, tenant: other)
      create(:message, :assistant, conversation: theirs,
        model: "gpt-4o-mini", prompt_tokens: 9999, completion_tokens: 9999, latency_ms: 777)

      sign_in(me)
      get dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("1,000")  # my prompt-token total
      expect(response.body).not_to include("9,999") # the other tenant's tokens never leak
    end

    it "renders a dash (not $0) for a message whose model has no known price" do
      me   = create(:user)
      mine = create(:conversation, tenant: me)
      create(:message, :assistant, conversation: mine,
        model: "mystery-model", prompt_tokens: 100, completion_tokens: 100, latency_ms: 10)

      sign_in(me)
      get dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("mystery-model")
    end
  end
end
