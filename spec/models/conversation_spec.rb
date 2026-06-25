require "rails_helper"

RSpec.describe Conversation, type: :model do
  it "is valid from the factory" do
    expect(build(:conversation)).to be_valid
  end

  it "requires a tenant" do
    conversation = build(:conversation, tenant: nil)
    expect(conversation).not_to be_valid
    expect(conversation.errors[:tenant_id]).to be_present
  end

  it "is scoped to its tenant via for_tenant" do
    mine = create(:conversation)
    create(:conversation) # someone else's

    expect(Conversation.for_tenant(mine.tenant)).to contain_exactly(mine)
  end

  it "destroys its messages when destroyed" do
    conversation = create(:conversation)
    create(:message, conversation: conversation)

    expect { conversation.destroy }.to change(Message, :count).by(-1)
  end

  it "orders messages by creation time" do
    conversation = create(:conversation)
    first = create(:message, conversation: conversation, created_at: 2.minutes.ago)
    second = create(:message, conversation: conversation, created_at: 1.minute.ago)

    expect(conversation.messages.to_a).to eq([ first, second ])
  end

  it "derives a truncated title from a question" do
    expect(Conversation.title_from("  Hello there  ")).to eq("Hello there")
    long = "word " * 50
    expect(Conversation.title_from(long).length).to be <= Conversation::TITLE_LENGTH
  end
end
