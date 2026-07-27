class RegistrationsController < ApplicationController
  allow_unauthenticated_access only: %i[new create]
  before_action :prevent_registration_in_demo_mode

  def new
    @user = User.new
  end

  def create
    @user = User.new(registration_params)

    if @user.save
      start_new_session_for(@user)
      redirect_to documents_path, notice: "Welcome!"
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def registration_params
    params.require(:user).permit(:email_address, :password, :password_confirmation)
  end

  def prevent_registration_in_demo_mode
    return unless DemoAccess.enabled?

    redirect_to root_path, alert: "Public registration is disabled for this portfolio demo." and return
  end
end
