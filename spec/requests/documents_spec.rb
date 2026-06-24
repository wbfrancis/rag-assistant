require "rails_helper"

RSpec.describe "Documents", type: :request do
  describe "authentication" do
    it "redirects anonymous users to sign in" do
      get documents_path
      expect(response).to redirect_to(new_session_path)
    end
  end

  describe "GET /documents" do
    it "shows the signed-in user's documents" do
      user = create(:user)
      mine = create(:document, tenant: user, title: "Mine")
      sign_in(user)

      get documents_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Mine")
      expect(mine).to be_persisted
    end
  end

  describe "POST /documents" do
    it "creates a pending document from pasted text and enqueues ingestion" do
      user = create(:user)
      sign_in(user)

      expect {
        post documents_path, params: { document: { title: "Pasted", body: "Some body text." } }
      }.to change { user.documents.count }.by(1)
        .and have_enqueued_job(IngestDocumentJob)

      document = user.documents.order(:created_at).last
      expect(document).to be_pending
      expect(document.raw_text).to eq("Some body text.")
      expect(response).to redirect_to(document)
    end
  end

  describe "tenant isolation" do
    it "does not let a user view another tenant's document" do
      owner = create(:user)
      other = create(:user)
      doc = create(:document, tenant: owner)

      sign_in(other)
      get document_path(doc)

      expect(response).to have_http_status(:not_found)
    end

    it "does not let a user destroy another tenant's document" do
      owner = create(:user)
      other = create(:user)
      doc = create(:document, tenant: owner)

      sign_in(other)
      expect { delete document_path(doc) }.not_to change(Document, :count)
      expect(response).to have_http_status(:not_found)
    end
  end
end
