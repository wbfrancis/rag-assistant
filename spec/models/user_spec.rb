require "rails_helper"

RSpec.describe User, type: :model do
  it "is valid from the factory" do
    expect(build(:user)).to be_valid
  end

  it "requires a unique email address" do
    create(:user, email_address: "dupe@example.com")
    dup = build(:user, email_address: "dupe@example.com")
    expect(dup).not_to be_valid
    expect(dup.errors[:email_address]).to be_present
  end

  it "normalizes the email address (trim + downcase)" do
    user = create(:user, email_address: "  Mixed@Example.COM ")
    expect(user.email_address).to eq("mixed@example.com")
  end

  it "authenticates with the correct password" do
    user = create(:user, password: "secret123")
    expect(user.authenticate("secret123")).to eq(user)
    expect(user.authenticate("wrong")).to be(false)
  end

  it "destroys its documents and chunks when destroyed" do
    user = create(:user)
    document = create(:document, tenant: user)
    create(:chunk, document: document)

    expect { user.destroy }
      .to change(Document, :count).by(-1)
      .and change(Chunk, :count).by(-1)
  end
end
