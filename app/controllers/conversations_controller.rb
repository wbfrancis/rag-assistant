class ConversationsController < ApplicationController
  # Every query goes through Current.user.conversations, so a user can only ever
  # reach their own conversations (tenant isolation, like DocumentsController).
  def index
    @conversations = Current.user.conversations.order(created_at: :desc)
  end

  def show
    @conversation = Current.user.conversations.find(params[:id])
    @messages = @conversation.messages
    @message = @conversation.messages.new
  end

  def create
    @conversation = Current.user.conversations.create!
    redirect_to @conversation
  end
end
