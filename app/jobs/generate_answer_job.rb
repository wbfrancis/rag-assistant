class GenerateAnswerJob < ApplicationJob
  include ActionView::RecordIdentifier

  queue_as :default

  # Transient LLM failures get a bounded retry with backoff; if the records are
  # gone there is nothing to answer into.
  retry_on LlmClient::RateLimitError, LlmClient::TimeoutError,
           wait: :polynomially_longer, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  # Runs the online query side off the web worker (so Puma is never blocked on a
  # slow model call) and broadcasts the answer into the conversation's Turbo
  # Stream as it streams (RAG_ASSISTANT_ARCHITECTURE.md §7, §8):
  #   contextualize → retrieve → generate (broadcasting tokens) → replace bubble.
  def perform(user_message_id:, assistant_message_id:)
    assistant    = Message.find(assistant_message_id)
    user_message = Message.find(user_message_id)
    conversation = assistant.conversation

    standalone = QueryContextualizer.new(
      conversation: conversation, question: user_message.content, current_message: user_message
    ).call
    retrieval  = Retriever.new(tenant: conversation.tenant, query: standalone).call

    AnswerGenerator.new(message: assistant, question: user_message.content, retrieval: retrieval).call do |token|
      broadcast_token(conversation, assistant, token)
    end

    broadcast_final(conversation, assistant)
  end

  private

  # Append one streamed token into the assistant bubble's body as it arrives.
  def broadcast_token(conversation, assistant, token)
    Turbo::StreamsChannel.broadcast_append_to(
      conversation,
      target: "#{dom_id(assistant)}_body",
      html: ERB::Util.html_escape(token)
    )
  end

  # Replace the whole bubble with the final rendered message — now including
  # citation links built from the persisted snapshot.
  def broadcast_final(conversation, assistant)
    Turbo::StreamsChannel.broadcast_replace_to(
      conversation,
      target: dom_id(assistant),
      partial: "messages/message",
      locals: { message: assistant }
    )
  end
end
