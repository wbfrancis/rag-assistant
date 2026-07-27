class DemoSessionsController < ApplicationController
  allow_unauthenticated_access only: :create

  def create
    user = DemoAccess.user

    unless DemoAccess.enabled? && user
      redirect_to root_path, alert: "The demo is not available yet." and return
    end

    start_demo_session_for(user)
    redirect_to conversations_path, notice: "Demo started. Try one of the suggested questions."
  end
end
