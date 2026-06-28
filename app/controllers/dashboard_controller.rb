class DashboardController < ApplicationController
  # Per-tenant usage view. Everything is
  # scoped through Current.user's conversations, so one tenant can never see
  # another's tokens or cost — the same isolation posture as the rest of the app.
  def show
    messages = Message.where(conversation_id: Current.user.conversations.select(:id)).assistant

    @conversation_count = Current.user.conversations.count
    @message_count      = messages.count
    @prompt_tokens      = messages.sum(:prompt_tokens)
    @completion_tokens  = messages.sum(:completion_tokens)
    @mean_latency_ms    = messages.average(:latency_ms)&.round
    @recent             = messages.order(created_at: :desc).limit(20).includes(:conversation)

    # Sum derived per-message cost over *all* assistant messages, pulling only the
    # three columns we need. Unknown-model messages return nil cost and are
    # skipped (not counted as free).
    @total_cost = messages.pluck(:model, :prompt_tokens, :completion_tokens).filter_map do |model, prompt, completion|
      LlmPricing.cost_for(model: model, prompt_tokens: prompt, completion_tokens: completion)
    end.sum
  end
end
