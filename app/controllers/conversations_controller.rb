class ConversationsController < ApplicationController
  # Every query goes through Current.user.conversations, so a user can only ever
  # reach their own conversations (tenant isolation, like DocumentsController).
  def index
    @conversations = accessible_conversations.order(created_at: :desc)
  end

  def show
    @conversation = accessible_conversations.find(params[:id])
    @messages = @conversation.messages
    @message = @conversation.messages.new
    set_doc_pane_state
  end

  def create
    @conversation = Current.user.conversations.create!
    remember_demo_conversation(@conversation)
    redirect_to @conversation
  end

  private

  # The document pane opens on whatever the most recent answer grounded
  # itself in — "click a citation and watch the source scroll into view" is
  # the demo moment, so a returning user sees it already open — falling back
  # to the document library when the conversation has no citations yet (or
  # the cited document/chunk has since been deleted; ADR 0004 keeps the
  # citation snapshot itself intact even then, we just can't show its source).
  def set_doc_pane_state
    cited_message = @conversation.messages.assistant.where.not(citations: []).order(created_at: :desc).first
    citation = cited_message&.citations&.first
    @doc_pane_document = citation && Current.user.documents.find_by(id: citation["document_id"])

    if @doc_pane_document
      @doc_pane_chunks = @doc_pane_document.chunks.order(:position)
      @active_chunk_id = citation["chunk_id"]
      similarity = cited_message.retrieval_scores.to_h[@active_chunk_id.to_s]
      @doc_pane_sim = similarity ? (similarity * 100).round : nil
    else
      @documents = Current.user.documents.order(created_at: :desc)
    end
  end
end
