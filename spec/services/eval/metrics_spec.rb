require "rails_helper"

# The deterministic core of the harness: pure functions, no DB, no LLM. These
# examples pin the scoring math against hand-built inputs.
RSpec.describe Eval::Metrics do
  describe ".contains_marker?" do
    it "matches when any marker is a substring of the content" do
      expect(described_class.contains_marker?("retains data for 90 days", [ "90 days" ])).to be(true)
    end

    it "is false when no marker appears" do
      expect(described_class.contains_marker?("unrelated text", [ "90 days" ])).to be(false)
    end
  end

  describe ".first_hit_rank" do
    let(:retrieved) { [ "alpha distractor", "beta with the needle here", "gamma" ] }

    it "returns the 1-based rank of the first chunk containing a marker" do
      expect(described_class.first_hit_rank(retrieved, [ "needle" ])).to eq(2)
    end

    it "returns nil when no chunk contains a marker" do
      expect(described_class.first_hit_rank(retrieved, [ "absent" ])).to be_nil
    end
  end

  describe ".reciprocal_rank" do
    it "is 1.0 for a top-ranked hit" do
      expect(described_class.reciprocal_rank([ "the needle", "x" ], [ "needle" ])).to eq(1.0)
    end

    it "is 1/rank for a lower hit" do
      expect(described_class.reciprocal_rank([ "x", "y", "the needle" ], [ "needle" ])).to be_within(1e-9).of(1.0 / 3)
    end

    it "is 0.0 when the gold source never appears" do
      expect(described_class.reciprocal_rank([ "x", "y" ], [ "needle" ])).to eq(0.0)
    end
  end

  describe ".mean" do
    it "averages present values" do
      expect(described_class.mean([ 1.0, 0.0, 1.0 ])).to be_within(1e-9).of(2.0 / 3)
    end

    it "ignores nils so an ungraded sample doesn't drag the mean to zero" do
      expect(described_class.mean([ 4, nil, 2 ])).to eq(3.0)
    end

    it "is nil when there are no present values (reads as n/a, not 0)" do
      expect(described_class.mean([ nil, nil ])).to be_nil
      expect(described_class.mean([])).to be_nil
    end
  end
end
