# Shared tenancy behaviour. Any model that include's this is owned by exactly
# one User (the "tenant") and can only be queried through that lens.
module TenantScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :tenant, class_name: "User"
    validates :tenant_id, presence: true
    scope :for_tenant, ->(user) { where(tenant_id: user.id) }
  end
end
