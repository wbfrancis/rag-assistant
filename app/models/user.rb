class User < ApplicationRecord
  has_secure_password

  has_many :documents, foreign_key: :tenant_id, inverse_of: :tenant, dependent: :destroy
  has_many :chunks, foreign_key: :tenant_id, inverse_of: :tenant, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.to_s.strip.downcase }

  validates :email_address, presence: true, uniqueness: true
end
