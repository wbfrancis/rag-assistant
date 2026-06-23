# Per-request holder for "who is logged in". Reset automatically between
# requests by Rails.
class Current < ActiveSupport::CurrentAttributes
  attribute :user
end
