# frozen_string_literal: true

# Turns a follow-up question into a standalone one (RAG_ASSISTANT_ARCHITECTURE.md
# §5). Multi-turn chat breaks naive retrieval: "what about its limits?" has no
# embeddable meaning on its own because "its" refers back up the conversation. So
# before the Retriever embeds anything, we condense the recent history + the new
# question into a self-contained query.
#
# The first turn is the common case and needs no rewriting, so it's a pure
# pass-through with *no* LLM call. Only follow-ups pay for a (cheap, non-streaming)
# chat completion. If the model returns nothing usable we fall back to the raw
# question rather than searching on an empty string.
class QueryContextualizer
  # How many prior messages to feed the rewriter. Enough to resolve coreference
  # without blowing up the prompt.
  HISTORY_TURNS = 6

  SYSTEM_PROMPT = <<~PROMPT.strip
    You rewrite a user's follow-up question into a standalone question that can be
    understood without the conversation history. Resolve any pronouns or references
    ("it", "its", "that", "the previous one") using the conversation. Do not answer
    the question. Output only the rewritten standalone question, nothing else.
  PROMPT

  # +current_message+ is the just-persisted user message for +question+; it (and
  # the blank assistant placeholder) must be excluded from the history so we don't
  # try to "contextualize" the question against itself.
  def initialize(conversation:, question:, current_message: nil)
    @conversation = conversation
    @question = question.to_s
    @current_message = current_message
  end

  def call
    history = recent_messages
    return @question if history.empty?

    rewritten = LlmClient.stream_chat(contextualization_messages(history)).to_s.strip
    rewritten.empty? ? @question : rewritten
  end

  private

  # Prior turns oldest-first, capped at HISTORY_TURNS. Excludes the just-created
  # user message for the current question (the caller passes that as @question).
  def recent_messages
    scope = @conversation.messages.where.not(content: "")
    scope = scope.where.not(id: @current_message.id) if @current_message
    scope.order(created_at: :desc).limit(HISTORY_TURNS).to_a.reverse
  end

  def contextualization_messages(history)
    turns = history.map { |m| { role: m.role, content: m.content } }
    [ { role: "system", content: SYSTEM_PROMPT } ] +
      turns +
      [ { role: "user", content: "Follow-up question: #{@question}\n\nStandalone question:" } ]
  end
end
