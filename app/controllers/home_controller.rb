class HomeController < ApplicationController
  allow_unauthenticated_access only: :show

  def show
    @demo_available = DemoAccess.available?
  end
end
