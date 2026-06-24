require "rails_helper"

RSpec.describe Chunk, type: :model do
  it "is valid from the factory" do
    expect(build(:chunk)).to be_valid
  end

  it "belongs to a document" do
    chunk = create(:chunk)
    expect(chunk.document).to be_a(Document)
  end

  it "copies tenant_id from its document before validation" do
    document = create(:document)
    chunk = build(:chunk, document: document, tenant: nil)

    expect(chunk).to be_valid
    expect(chunk.tenant_id).to eq(document.tenant_id)
  end
end
