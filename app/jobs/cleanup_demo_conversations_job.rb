class CleanupDemoConversationsJob < ApplicationJob
  queue_as :default

  def perform
    user = User.find_by(email_address: DemoAccess.email_address)
    return unless user

    user.conversations.where(updated_at: ...24.hours.ago).find_each(&:destroy!)
  end
end
