class Chunk < ApplicationRecord
  include TenantScoped

  belongs_to :document

  has_neighbors :embedding   # neighbor gem: nearest-neighbor search on the vector

  # Copy tenant_id down from the parent document so we never forget to set it.
  before_validation :copy_tenant_from_document

  private

  def copy_tenant_from_document
    self.tenant_id ||= document&.tenant_id
  end
end
