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
    was_demo = demo_session?
    terminate_session
    redirect_to was_demo ? root_path : new_session_path, notice: was_demo ? "Demo ended." : "Signed out."
  end
end
