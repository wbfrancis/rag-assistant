require "rails_helper"

RSpec.describe "Portfolio demo", type: :request do
  around do |example|
    original_mode = ENV["DEMO_MODE"]
    original_email = ENV["DEMO_USER_EMAIL"]
    ENV["DEMO_MODE"] = "true"
    ENV["DEMO_USER_EMAIL"] = "demo@example.com"
    example.run
  ensure
    ENV["DEMO_MODE"] = original_mode
    ENV["DEMO_USER_EMAIL"] = original_email
  end

  let!(:demo_user) { create(:user, email_address: "demo@example.com") }

  it "describes the assistant and demo composer with the approved copy" do
    get root_path

    expect(response.parsed_body.text).to include(
      "This LLM-powered assistant retrieves relevant passages from a collection of documents"
    )

    post demo_session_path
    post conversations_path
    get conversation_path(demo_user.conversations.order(:created_at).last)

    expect(response.body).to include("Ask how this assistant works...")
  end

  it "starts without a password and shows only conversations from this demo session" do
    previous = create(:conversation, tenant: demo_user, title: "Another visitor")

    post demo_session_path
    expect(response).to redirect_to(conversations_path)

    get conversations_path
    expect(response.body).not_to include(previous.title)

    expect { post conversations_path }.to change(demo_user.conversations, :count).by(1)
    conversation = demo_user.conversations.order(:created_at).last

    get conversation_path(conversation)
    expect(response).to have_http_status(:ok)
  end

  it "does not allow a demo visitor to open another visitor's conversation" do
    other = create(:conversation, tenant: demo_user)
    post demo_session_path

    get conversation_path(other)

    expect(response).to have_http_status(:not_found)
  end

  it "prevents document changes in demo mode" do
    post demo_session_path

    get new_document_path

    expect(response).to redirect_to(documents_path)
  end

  it "disables public registration when demo mode is enabled" do
    get new_registration_path

    expect(response).to redirect_to(root_path)
  end
end
