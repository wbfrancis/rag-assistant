# Helper for request specs: log a user in by POSTing real credentials, so the
# session cookie is set exactly as it would be in the browser.
module AuthenticationHelpers
  def sign_in(user, password: "password123")
    post session_path, params: { email_address: user.email_address, password: password }
  end
end

RSpec.configure do |config|
  config.include AuthenticationHelpers, type: :request
end
