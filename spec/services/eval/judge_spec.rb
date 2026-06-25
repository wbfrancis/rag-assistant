require "rails_helper"

RSpec.describe Eval::Judge do
  def judge(samples: 1)
    described_class.new(
      question: "How long is free-tier retention?",
      reference_answer: "90 days.",
      generated_answer: "The free tier keeps data for 90 days.",
      samples: samples
    ).call
  end

  it "parses a JSON verdict into a clamped score" do
    LlmClient.backend = FakeLlmClient.new(chat_tokens: [ '{"score": 5, "rationale": "faithful"}' ])

    result = judge

    expect(result[:score]).to eq(5.0)
    expect(result[:rationale]).to eq("faithful")
  end

  it "extracts JSON even when the model wraps it in prose" do
    LlmClient.backend = FakeLlmClient.new(chat_tokens: [ "Here is my grade: ", '{"score": 4}', " done." ])

    expect(judge[:score]).to eq(4.0)
  end

  it "clamps an out-of-range score into 1..5" do
    LlmClient.backend = FakeLlmClient.new(chat_tokens: [ '{"score": 9}' ])

    expect(judge[:score]).to eq(5.0)
  end

  it "returns a nil score on malformed output instead of raising" do
    LlmClient.backend = FakeLlmClient.new(chat_tokens: [ "not json at all" ])

    expect { judge }.not_to raise_error
    expect(judge[:score]).to be_nil
  end

  it "averages several samples to reduce flap" do
    # Two grades, 5 then 3 -> mean 4. The Fake yields the same canned tokens each
    # call, so to vary scores we stub stream_chat to return a sequence.
    backend = FakeLlmClient.new
    responses = [ '{"score": 5}', '{"score": 3}' ]
    allow(backend).to receive(:stream_chat).and_return(*responses)
    LlmClient.backend = backend

    expect(judge(samples: 2)[:score]).to eq(4.0)
  end
end
