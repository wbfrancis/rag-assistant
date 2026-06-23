# Minimal session-cookie authentication for the Phase 1 thin slice.
# (The full Rails 8 generator-based auth is what the plan calls for; this is a
# slimmed-down, hand-rolled equivalent good enough to demo end-to-end.)
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :current_user
  end

  class_methods do
    # Lets specific controllers/actions opt out of the login requirement.
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private

  def current_user
    Current.user ||= User.find_by(id: session[:user_id])
  end

  def require_authentication
    current_user || request_authentication
  end

  def request_authentication
    redirect_to new_session_path, alert: "Please sign in to continue."
  end

  def start_new_session_for(user)
    Current.user = user
    reset_session
    session[:user_id] = user.id
  end

  def terminate_session
    Current.user = nil
    reset_session
  end
end
