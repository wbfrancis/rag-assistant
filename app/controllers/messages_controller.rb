class MessagesController < ApplicationController
  # Post a question into one of the current user's conversations. The conversation
  # is always loaded tenant-scoped, so a user cannot inject a message into someone
  # else's conversation. The controller stays thin: it persists the user's
  # question, creates a blank assistant placeholder to stream into, and hands the
  # slow work to GenerateAnswerJob.
  def create
    conversation = Current.user.conversations.find(params[:conversation_id])
    question = message_params[:content].to_s.strip

    if question.blank?
      redirect_to conversation, alert: "Please enter a question." and return
    end

    @conversation = conversation
    @user_message = conversation.messages.create!(role: :user, content: question)
    conversation.update!(title: Conversation.title_from(question)) if conversation.title.blank?
    @assistant = conversation.messages.create!(role: :assistant, content: "")

    GenerateAnswerJob.perform_later(user_message_id: @user_message.id, assistant_message_id: @assistant.id)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to conversation }
    end
  end

  private

  def message_params
    params.require(:message).permit(:content)
  end
end
