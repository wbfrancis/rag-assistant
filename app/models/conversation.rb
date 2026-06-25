class Conversation < ApplicationRecord
  include TenantScoped

  has_many :messages, -> { order(:created_at) }, dependent: :destroy

  # A short title derived from the first question, for the conversations list.
  TITLE_LENGTH = 60

  def self.title_from(question)
    question.to_s.strip.truncate(TITLE_LENGTH)
  end
end
