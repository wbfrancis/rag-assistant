class Message < ApplicationRecord
  belongs_to :conversation

  enum :role, { user: 0, assistant: 1 }

  # A user message must have content. An assistant message is created as a blank
  # placeholder and filled in as tokens stream, so only require its content once
  # it is no longer a new record being saved empty on purpose.
  validates :content, presence: true, if: :user?
end
