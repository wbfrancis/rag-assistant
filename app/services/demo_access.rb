class DemoAccess
  DEFAULT_EMAIL = "demo@willbfrancis.com"
  DEFAULT_SESSION_QUESTION_LIMIT = 12
  DEFAULT_DAILY_QUESTION_LIMIT = 250

  class << self
    def enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("DEMO_MODE", "false"))
    end

    def available?
      enabled? && user.present?
    end

    def user
      return unless enabled?

      User.find_by(email_address: email_address)
    end

    def email_address
      ENV.fetch("DEMO_USER_EMAIL", DEFAULT_EMAIL)
    end

    def question_allowed?(user:, conversation_ids:)
      return false if conversation_ids.blank?
      return false if session_question_count(user:, conversation_ids:) >= session_question_limit

      daily_question_count(user:) < daily_question_limit
    end

    def session_question_limit
      ENV.fetch("DEMO_SESSION_QUESTION_LIMIT", DEFAULT_SESSION_QUESTION_LIMIT).to_i
    end

    def daily_question_limit
      ENV.fetch("DEMO_DAILY_QUESTION_LIMIT", DEFAULT_DAILY_QUESTION_LIMIT).to_i
    end

    private

    def session_question_count(user:, conversation_ids:)
      user_messages(user:).where(conversations: { id: conversation_ids }).count
    end

    def daily_question_count(user:)
      user_messages(user:).where(messages: { created_at: Time.current.all_day }).count
    end

    def user_messages(user:)
      Message.user.joins(:conversation).where(conversations: { tenant_id: user.id })
    end
  end
end
