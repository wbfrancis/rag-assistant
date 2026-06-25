require "rails_helper"
require "tmpdir"

RSpec.describe Eval::Dataset do
  # Write a corpus.yml + questions.yml into a tmp dir and load it.
  def write_dataset(corpus:, questions:)
    dir = Dir.mktmpdir
    File.write(File.join(dir, "corpus.yml"), corpus.to_yaml)
    File.write(File.join(dir, "questions.yml"), questions.to_yaml)
    dir
  end

  let(:corpus) { [ { "title" => "Doc", "body" => "Helios retains data for 90 days." } ] }

  it "loads corpus docs and questions into value objects" do
    dir = write_dataset(
      corpus: corpus,
      questions: [ { "id" => "q1", "question" => "How long?", "expected_markers" => [ "90 days" ], "reference_answer" => "90 days." } ]
    )

    dataset = described_class.load(dir: dir)

    expect(dataset.corpus.first).to be_a(Eval::CorpusDoc)
    expect(dataset.questions.first).to be_a(Eval::Question)
    expect(dataset.questions.first.markers).to eq([ "90 days" ])
  end

  it "treats out_of_corpus questions as abstention cases needing no markers" do
    dir = write_dataset(
      corpus: corpus,
      questions: [ { "id" => "oc", "question" => "Capital of France?", "out_of_corpus" => true } ]
    )

    dataset = described_class.load(dir: dir)

    expect(dataset.questions.first).to be_out_of_corpus
  end

  it "raises when a marker appears in no corpus body (catches fixture typos)" do
    dir = write_dataset(
      corpus: corpus,
      questions: [ { "id" => "q1", "question" => "How long?", "expected_markers" => [ "five years" ], "reference_answer" => "x" } ]
    )

    expect { described_class.load(dir: dir) }.to raise_error(Eval::Dataset::InvalidError, /absent from the corpus/)
  end

  it "raises when an answerable question has no reference answer" do
    dir = write_dataset(
      corpus: corpus,
      questions: [ { "id" => "q1", "question" => "How long?", "expected_markers" => [ "90 days" ] } ]
    )

    expect { described_class.load(dir: dir) }.to raise_error(Eval::Dataset::InvalidError, /reference_answer/)
  end

  it "raises when a fixture file is missing" do
    expect { described_class.load(dir: Dir.mktmpdir) }.to raise_error(Eval::Dataset::InvalidError, /Missing fixture/)
  end
end
