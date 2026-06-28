require "rails_helper"
require "tmpdir"

# End-to-end harness smoke test on the deterministic Fake. The Fake only matches
# verbatim text, so the fixtures here phrase each answerable question as the
# *exact* body of its source document — that body becomes a single chunk, embeds
# to the same vector as the query, and is retrieved at similarity 1.0 (ADR 0005,
# decision 3). That gives a known-perfect baseline and exercises the full
# seed -> retrieve -> (generate) -> score -> rollback path offline.
RSpec.describe Eval::Runner do
  let(:fake) { FakeLlmClient.new }

  before { LlmClient.backend = fake }

  # Two answerable docs (question == body, marker is a substring) and one
  # out-of-corpus question that matches nothing.
  def deterministic_dataset
    corpus = [
      { "title" => "Retention", "body" => "The Helios free tier retains telemetry data for 90 days." },
      { "title" => "Rate limit", "body" => "The Helios API allows 100 requests per minute per account." }
    ]
    questions = [
      { "id" => "retention", "question" => "The Helios free tier retains telemetry data for 90 days.",
        "expected_markers" => [ "90 days" ], "reference_answer" => "90 days." },
      { "id" => "rate", "question" => "The Helios API allows 100 requests per minute per account.",
        "expected_markers" => [ "100 requests per minute" ], "reference_answer" => "100 per minute." },
      { "id" => "oc", "question" => "totally unrelated out of corpus phrase", "out_of_corpus" => true }
    ]

    dir = Dir.mktmpdir
    File.write(File.join(dir, "corpus.yml"), corpus.to_yaml)
    File.write(File.join(dir, "questions.yml"), questions.to_yaml)
    Eval::Dataset.load(dir: dir)
  end

  it "scores perfect recall/MRR on the verbatim baseline and abstains out-of-corpus" do
    report = described_class.new(dataset: deterministic_dataset).call

    summary = report.summary
    expect(summary[:recall_at_k]).to eq(1.0)
    expect(summary[:mrr]).to eq(1.0)
    expect(summary[:abstention_accuracy]).to eq(1.0)
    expect(summary[:answerable]).to eq(2)
    expect(summary[:out_of_corpus]).to eq(1)
  end

  it "leaves no database residue (the whole run is rolled back)" do
    counts = -> { [ User.count, Document.count, Chunk.count, Conversation.count, Message.count ] }
    before = counts.call

    described_class.new(dataset: deterministic_dataset, judge: true).call

    expect(counts.call).to eq(before)
  end

  it "reports a judge score when judging is enabled" do
    LlmClient.backend = FakeLlmClient.new(chat_tokens: [ '{"score": 5, "rationale": "ok"}' ])

    report = described_class.new(dataset: deterministic_dataset, judge: true).call

    # Answers are generated and graded via the real AnswerGenerator + Judge.
    expect(report.summary[:mean_judge]).to eq(5.0)
  end

  it "does not generate or grade answers when judging is off" do
    described_class.new(dataset: deterministic_dataset, judge: false).call

    # No chat completions at all on the retrieval-only path (embeddings only).
    expect(fake.chat_calls).to eq(0)
  end

  it "counts a generation-layer decline as abstaining and does not grade it" do
    # The question clears the relevance floor (verbatim match), so the Retriever
    # does NOT abstain — but the model returns ABSTAIN_MESSAGE, the second-layer
    # grounding guardrail. The run must treat that as a decline (ADR 0005).
    LlmClient.backend = FakeLlmClient.new(chat_tokens: [ AnswerGenerator::ABSTAIN_MESSAGE ])

    report = described_class.new(dataset: deterministic_dataset, judge: true).call
    row = report.rows.find { |r| r[:id] == "retention" }

    expect(row[:abstained]).to be(true)        # declined at generation, not at the floor
    expect(report.summary[:mean_judge]).to be_nil  # a declined answer is not graded
  end

  it "recognizes a model-phrased \"I don't know\" as a decline (not a fabrication)" do
    # The model refuses in its own words rather than emitting the canned message;
    # an exact-string check would miss it and undercount abstention.
    LlmClient.backend = FakeLlmClient.new(chat_tokens: [ "I don't know." ])

    report = described_class.new(dataset: deterministic_dataset, judge: true).call
    row = report.rows.find { |r| r[:id] == "retention" }

    expect(row[:abstained]).to be(true)
  end
end
