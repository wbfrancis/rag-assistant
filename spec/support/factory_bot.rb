# Always persist associated records, even when only *building* the parent, so
# that foreign keys (e.g. documents.tenant_id) are populated and our
# `validates :tenant_id, presence: true` checks pass with build(:document).
FactoryBot.use_parent_strategy = false
