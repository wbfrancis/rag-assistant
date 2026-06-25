require "rails_helper"

RSpec.describe AnswerGenerator do
  let(:fake) { FakeLlmClient.new }

  before { LlmClient.backend = fake }

  def assistant_message(conversation: create(:conversation))
    create(:message, :assistant, conversation: conversation, content: "")
  end

  def result_for(scored)
    Retriever::Result.new(scored: scored, abstained: false, top_similarity: scored.first&.last)
  end

  describe "grounded generation" do
    it "delimits the context, includes the question, and persists grounding metadata" do
      doc = create(:document, title: "Handbook")
      chunk = create(:chunk, document: doc, content: "The sky is blue.",
                             content_hash: "h1", token_count: 5)
      message = assistant_message

      captured = nil
      allow(LlmClient).to receive(:stream_chat) do |messages, **_kw, &blk|
        captured = messages
        blk&.call("Blue.")
        "Blue."
      end

      answer = described_class.new(message: message, question: "What colour is the sky?",
                                   retrieval: result_for([ [ chunk, 0.9 ] ])).call

      user_content = captured.last[:content]
      expect(user_content).to include("The sky is blue.")
      expect(user_content).to include("What colour is the sky?")
      expect(user_content).to match(/untrusted/i)

      expect(answer).to eq("Blue.")
      message.reload
      expect(message.content).to eq("Blue.")
      expect(message.chunk_ids).to eq([ chunk.id ])
      expect(message.citations.first["document_title"]).to eq("Handbook")
      expect(message.retrieval_scores[chunk.id]).to eq(0.9)
      expect(message.model).to eq(LlmClient.config.chat_model)
      expect(message.prompt_tokens).to be > 0
      expect(message.completion_tokens).to be > 0
      expect(message.latency_ms).to be >= 0
    end

    it "streams each token to the caller's block" do
      chunk = create(:chunk, content: "grounded", content_hash: "h", token_count: 3)
      message = assistant_message

      tokens = []
      described_class.new(message: message, question: "q",
                          retrieval: result_for([ [ chunk, 0.8 ] ])).call { |t| tokens << t }

      expect(tokens.join).to eq(FakeLlmClient::CANNED_TOKENS.join)
    end
  end

  describe "abstention guardrail" do
    it "persists a canned reply and never calls the model when retrieval abstained" do
      message = assistant_message
      retrieval = Retriever::Result.new(scored: [], abstained: true, top_similarity: 0.1)

      expect(LlmClient).not_to receive(:stream_chat)

      answer = described_class.new(message: message, question: "off topic", retrieval: retrieval).call

      expect(answer).to eq(described_class::ABSTAIN_MESSAGE)
      message.reload
      expect(message.content).to eq(described_class::ABSTAIN_MESSAGE)
      expect(message.chunk_ids).to be_empty
      expect(message.citations).to be_empty
    end
  end

  describe "context assembly" do
    it "stops packing chunks once the token budget is spent" do
      doc = create(:document)
      big = AnswerGenerator::CONTEXT_TOKEN_BUDGET
      a = create(:chunk, document: doc, position: 0, content: "first",  content_hash: "a", token_count: big - 100)
      b = create(:chunk, document: doc, position: 5, content: "second", content_hash: "b", token_count: big - 100)
      message = assistant_message

      described_class.new(message: message, question: "q",
                          retrieval: result_for([ [ a, 0.9 ], [ b, 0.8 ] ])).call

      expect(message.reload.chunk_ids).to eq([ a.id ])
    end

    it "drops duplicate chunks sharing a content_hash" do
      doc = create(:document)
      a = create(:chunk, document: doc, position: 0, content: "dup", content_hash: "same", token_count: 5)
      b = create(:chunk, document: doc, position: 9, content: "dup", content_hash: "same", token_count: 5)
      message = assistant_message

      described_class.new(message: message, question: "q",
                          retrieval: result_for([ [ a, 0.9 ], [ b, 0.85 ] ])).call

      expect(message.reload.chunk_ids).to eq([ a.id ])
    end
  end
end
