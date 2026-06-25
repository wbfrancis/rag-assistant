require "rails_helper"

RSpec.describe Message, type: :model do
  it "is valid from the factory" do
    expect(build(:message)).to be_valid
  end

  it "belongs to a conversation" do
    expect(create(:message).conversation).to be_a(Conversation)
  end

  it "exposes role predicates via the enum" do
    expect(build(:message, role: :user)).to be_user
    expect(build(:message, :assistant)).to be_assistant
  end

  it "requires content on a user message" do
    message = build(:message, role: :user, content: "")
    expect(message).not_to be_valid
    expect(message.errors[:content]).to be_present
  end

  it "allows a blank assistant placeholder (filled as it streams)" do
    expect(build(:message, role: :assistant, content: "")).to be_valid
  end

  it "round-trips a uuid array of chunk_ids" do
    ids = [ SecureRandom.uuid, SecureRandom.uuid ]
    message = create(:message, :assistant, chunk_ids: ids)
    expect(message.reload.chunk_ids).to eq(ids)
  end
end
