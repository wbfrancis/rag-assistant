require "rails_helper"

RSpec.describe CleanupDemoConversationsJob do
  it "removes expired demo conversations without touching recent ones" do
    user = create(:user, email_address: DemoAccess.email_address)
    expired = create(:conversation, tenant: user, updated_at: 25.hours.ago)
    recent = create(:conversation, tenant: user, updated_at: 2.hours.ago)

    described_class.perform_now

    expect(Conversation.exists?(expired.id)).to be(false)
    expect(Conversation.exists?(recent.id)).to be(true)
  end
end
