class Document < ApplicationRecord
  include TenantScoped

  has_many :chunks, dependent: :destroy

  # Uploaded files (PDFs, text) live in Active Storage rather than the raw_text
  # column; pasted text still uses raw_text. See DocumentIngestor#source_bytes.
  has_one_attached :file

  enum :status, { pending: 0, processing: 1, processed: 2, failed: 3 }

  validates :title, :content_type, presence: true
end
