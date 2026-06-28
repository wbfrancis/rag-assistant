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
  # Stream as it streams:
  #   contextualize → retrieve → (re-rank) → generate (broadcasting tokens) → replace.
  def perform(user_message_id:, assistant_message_id:)
    assistant    = Message.find(assistant_message_id)
    user_message = Message.find(user_message_id)
    conversation = assistant.conversation

    standalone = QueryContextualizer.new(
      conversation: conversation, question: user_message.content, current_message: user_message
    ).call
    retrieval  = retrieve(conversation.tenant, standalone)

    AnswerGenerator.new(message: assistant, question: user_message.content, retrieval: retrieval).call do |token|
      broadcast_token(conversation, assistant, token)
    end

    broadcast_final(conversation, assistant)
  end

  private

  # Hybrid retrieval, then an optional LLM re-rank second stage (ADR 0008). When
  # re-rank is enabled we retrieve a *wider* candidate pool so the model has room
  # to promote a chunk the fusion ranked low; the Reranker reorders and the
  # AnswerGenerator's token budget packs the best-first context. Re-rank is
  # never-worse-than-fused, so a flaky model call degrades to plain hybrid.
  def retrieve(tenant, standalone)
    rerank    = Reranker.enabled?
    pool_k    = rerank ? Retriever::DEFAULT_CANDIDATE_K : Retriever::DEFAULT_K
    retrieval = Retriever.new(tenant: tenant, query: standalone, k: pool_k).call
    return retrieval unless rerank

    Reranker.new(query: standalone, result: retrieval, k: Retriever::DEFAULT_K).call
  end

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
