require "rails_helper"

RSpec.describe LlmPricing do
  describe ".cost_for" do
    it "computes input + output cost from per-1K-token prices" do
      # gpt-4o-mini: $0.00015 input / $0.0006 output per 1K tokens.
      cost = described_class.cost_for(model: "gpt-4o-mini", prompt_tokens: 1000, completion_tokens: 1000)
      expect(cost).to be_within(1e-9).of(0.00015 + 0.0006)
    end

    it "scales linearly with token counts" do
      cost = described_class.cost_for(model: "gpt-4o-mini", prompt_tokens: 2000, completion_tokens: 0)
      expect(cost).to be_within(1e-9).of(2 * 0.00015)
    end

    it "returns nil for an unknown model rather than implying it was free" do
      expect(described_class.cost_for(model: "mystery-model", prompt_tokens: 100, completion_tokens: 100)).to be_nil
    end

    it "treats nil token counts as zero" do
      expect(described_class.cost_for(model: "gpt-4o-mini", prompt_tokens: nil, completion_tokens: nil)).to eq(0.0)
    end
  end
end
