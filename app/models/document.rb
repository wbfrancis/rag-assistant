class Document < ApplicationRecord
  include TenantScoped

  has_many :chunks, dependent: :destroy

  enum :status, { pending: 0, processing: 1, processed: 2, failed: 3 }

  validates :title, :content_type, presence: true
end
