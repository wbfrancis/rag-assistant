require "rails_helper"

RSpec.describe Document, type: :model do
  it "is valid from the factory" do
    expect(build(:document)).to be_valid
  end

  it "requires a title" do
    doc = build(:document, title: nil)
    expect(doc).not_to be_valid
    expect(doc.errors[:title]).to be_present
  end

  it "requires a content_type" do
    doc = build(:document, content_type: nil)
    expect(doc).not_to be_valid
    expect(doc.errors[:content_type]).to be_present
  end

  it "requires a tenant_id (tenancy enforcement)" do
    doc = build(:document, tenant: nil)
    expect(doc).not_to be_valid
    expect(doc.errors[:tenant_id]).to be_present
  end

  it "exposes the status enum helpers" do
    doc = build(:document, status: :processed)
    expect(doc).to be_processed
    expect(Document.statuses).to include("pending" => 0, "failed" => 3)
  end

  it "destroys its chunks when destroyed" do
    document = create(:document)
    create(:chunk, document: document)
    expect { document.destroy }.to change(Chunk, :count).by(-1)
  end

  describe ".for_tenant" do
    it "returns only the given tenant's documents" do
      user_a = create(:user)
      user_b = create(:user)
      mine = create(:document, tenant: user_a)
      create(:document, tenant: user_b)

      expect(Document.for_tenant(user_a)).to contain_exactly(mine)
    end
  end
end
