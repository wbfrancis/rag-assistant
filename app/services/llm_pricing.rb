# frozen_string_literal: true

# Per-model token pricing for the cost dashboard (RAG_ASSISTANT_ARCHITECTURE.md
# §10). We persist only *token counts* on messages; the dollar cost is derived
# here on read, because provider prices change over time — baking a computed
# dollar amount into a column would freeze a number that goes stale and
# duplicate state we can already recompute (Phase 5 plan, decision 1).
#
# Prices are USD per 1,000 tokens, split input (prompt) vs output (completion).
# An unknown model returns +nil+ cost (rendered as "—") rather than guessing or
# implying it was free.
module LlmPricing
  # USD per 1K tokens. Deliberately a plain, obviously editable table — it is
  # pricing data, not secret config. Update when provider prices change.
  PRICES = {
    "gpt-4o-mini"            => { input: 0.00015, output: 0.0006 },
    "gpt-4o"                 => { input: 0.0025,  output: 0.01 },
    "text-embedding-3-small" => { input: 0.00002, output: 0.0 },
    "text-embedding-3-large" => { input: 0.00013, output: 0.0 }
  }.freeze

  module_function

  # Derived USD cost for one message's token usage, or +nil+ when the model is
  # unknown (so the caller can render "—" instead of a misleading $0.00).
  def cost_for(model:, prompt_tokens:, completion_tokens:)
    price = PRICES[model]
    return nil if price.nil?

    input_cost  = (prompt_tokens.to_i / 1000.0) * price[:input]
    output_cost = (completion_tokens.to_i / 1000.0) * price[:output]
    input_cost + output_cost
  end
end
