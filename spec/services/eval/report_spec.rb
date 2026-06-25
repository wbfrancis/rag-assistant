require "rails_helper"

RSpec.describe Eval::Report do
  def build(rows)
    described_class.new(rows: rows, k: 8, min_similarity: 0.3, backend: "FakeLlmClient", judged: false)
  end

  let(:rows) do
    [
      { id: "a", out_of_corpus: false, abstained: false, hit: true,  reciprocal_rank: 1.0, judge_score: 5 },
      { id: "b", out_of_corpus: false, abstained: false, hit: false, reciprocal_rank: 0.0, judge_score: nil },
      { id: "c", out_of_corpus: true,  abstained: true,  hit: nil,   reciprocal_rank: nil, judge_score: nil }
    ]
  end

  describe "#summary" do
    it "computes recall@k, MRR, and abstention accuracy over the right subsets" do
      summary = build(rows).summary

      expect(summary[:recall_at_k]).to eq(0.5)            # 1 of 2 answerable hit
      expect(summary[:mrr]).to eq(0.5)                    # (1.0 + 0.0) / 2
      expect(summary[:abstention_accuracy]).to eq(1.0)    # 1 of 1 out-of-corpus abstained
      expect(summary[:mean_judge]).to eq(5.0)             # nil judge score ignored
      expect(summary[:answerable]).to eq(2)
      expect(summary[:out_of_corpus]).to eq(1)
    end

    it "reports n/a (nil) for a metric with no data" do
      summary = build([ { id: "a", out_of_corpus: false, abstained: false, hit: true, reciprocal_rank: 1.0, judge_score: nil } ]).summary

      expect(summary[:abstention_accuracy]).to be_nil    # no out-of-corpus questions
      expect(summary[:mean_judge]).to be_nil
    end
  end

  describe "#meets? / #failures" do
    it "passes when every threshold is met" do
      report = build(rows)
      expect(report.meets?(recall_at_k: 0.5, abstention_accuracy: 1.0)).to be(true)
    end

    it "fails and names the metric when a threshold is unmet" do
      report = build(rows)

      expect(report.meets?(recall_at_k: 0.9)).to be(false)
      expect(report.failures(recall_at_k: 0.9).first).to match(/recall@k/)
    end

    it "fails when a thresholded metric has no data (nil)" do
      report = build([ { id: "a", out_of_corpus: false, abstained: false, hit: true, reciprocal_rank: 1.0, judge_score: nil } ])

      expect(report.meets?(abstention_accuracy: 0.5)).to be(false)
    end
  end

  describe "#to_table and #to_json" do
    it "renders the summary metrics in the table" do
      table = build(rows).to_table

      expect(table).to include("recall@k", "MRR", "abstention accuracy")
      expect(table).to include("backend=FakeLlmClient")
    end

    it "round-trips through JSON with summary and rows" do
      parsed = JSON.parse(build(rows).to_json)

      expect(parsed["summary"]["recall_at_k"]).to eq(0.5)
      expect(parsed["rows"].size).to eq(3)
    end
  end
end
