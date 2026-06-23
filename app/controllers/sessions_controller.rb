class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[new create]

  def new
  end

  def create
    user = User.find_by(email_address: params[:email_address].to_s.strip.downcase)

    if user&.authenticate(params[:password])
      start_new_session_for(user)
      redirect_to documents_path, notice: "Signed in."
    else
      flash.now[:alert] = "Invalid email or password."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, notice: "Signed out."
  end
end
