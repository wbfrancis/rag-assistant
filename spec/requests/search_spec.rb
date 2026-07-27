require "rails_helper"

RSpec.describe "Search", type: :request do
  before { LlmClient.backend = FakeLlmClient.new }

  describe "authentication" do
    it "redirects anonymous users to sign in" do
      get search_path
      expect(response).to redirect_to(new_session_path)
    end
  end

  describe "GET /search" do
    it "explains what search can and cannot do" do
      user = create(:user)
      sign_in(user)

      get search_path

      expect(response.body).to include("Search shows the passages the assistant could use")
      expect(response.body).to include("Works well")
      expect(response.body).to include("Does not")
      expect(response.body).to include("search outside your collection")
    end

    it "shows ranked results from the user's own chunks with similarity" do
      user = create(:user)
      doc = create(:document, tenant: user, title: "My Doc")
      create(:chunk, :embedded, document: doc, content: "the answer is forty two")
      sign_in(user)

      get search_path, params: { q: "the answer is forty two" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("My Doc")
      expect(response.body).to include("the answer is forty two")
      expect(response.body).to match(/similarity\s+1\.000/) # cosine similarity 1.0
    end

    it "renders the abstain message for an unrelated query" do
      user = create(:user)
      doc = create(:document, tenant: user)
      create(:chunk, :embedded, document: doc, content: "alpha beta gamma delta")
      sign_in(user)

      get search_path, params: { q: "wholly unrelated nonsense phrase" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No sufficiently relevant context found")
    end
  end

  describe "tenant isolation" do
    it "does not surface another tenant's chunks" do
      a = create(:user)
      b = create(:user)
      doc_b = create(:document, tenant: b, title: "Owned By B")
      create(:chunk, :embedded, document: doc_b, content: "confidential bravo content")
      sign_in(a)

      # A searches the exact content only B owns; with the tenant pre-filter this
      # finds nothing and abstains rather than leaking B's row.
      get search_path, params: { q: "confidential bravo content" }

      expect(response.body).not_to include("Owned By B")
      expect(response.body).to include("No sufficiently relevant context found")
    end
  end
end
