# frozen_string_literal: true

module Eval
  # Orchestrates one evaluation: seed a fixture corpus, run every question through
  # the *real* Retriever (and, when judging, the real AnswerGenerator), score it,
  # and return a Report.
  #
  # The whole run lives inside a single +requires_new: true+ transaction that is
  # always rolled back (ADR 0005, decision 2), so the eval tenant, its documents,
  # chunks, and any throwaway conversations leave **no DB residue** — and the same
  # rollback works whether or not an outer transaction is present (e.g. RSpec's
  # transactional fixtures), which a plain nested transaction would not.
  class Runner
    def initialize(dataset:, k: 8, min_similarity: Retriever::RELEVANCE_FLOOR, judge: false, samples: 1)
      @dataset = dataset
      @k = k
      @min_similarity = min_similarity
      @judge = judge
      @samples = samples
    end

    def call
      rows = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        tenant = CorpusSeeder.new(dataset: @dataset).seed
        rows = @dataset.questions.map { |question| evaluate(question, tenant) }
        raise ActiveRecord::Rollback
      end

      Report.new(rows: rows, k: @k, min_similarity: @min_similarity, backend: backend_name, judged: @judge)
    end

    private

    def evaluate(question, tenant)
      retrieval = Retriever.new(tenant: tenant, query: question.text, k: @k, min_similarity: @min_similarity).call
      retrieved_contents = retrieval.chunks.map(&:content)

      # When judging, generate the answer once and reuse it for both the
      # abstention check and the grade. The system declines in *two* layers
      # (ADR 0005): the Retriever's relevance floor, and AnswerGenerator's
      # grounding prompt returning ABSTAIN_MESSAGE when the cleared-the-floor
      # context still doesn't answer the question — the latter is what catches
      # on-topic near-miss questions the floor alone lets through. With judging
      # off we measure the floor layer only (deterministic, retrieval-focused).
      answer = (@judge ? generate_answer(question, retrieval, tenant) : nil)
      declined = declined?(retrieval, answer)

      base = {
        id: question.id,
        question: question.text,
        out_of_corpus: question.out_of_corpus?,
        abstained: declined,
        retrieved_count: retrieved_contents.size,
        # Captured so the JSON artifact is diagnostic: an exact-string abstention
        # check can't tell a fabrication from a model-phrased "I don't know", so
        # near-miss OOC answers must be eyeballed (ADR 0005). nil when not judging.
        answer: answer&.truncate(300)
      }

      return base.merge(hit: nil, reciprocal_rank: nil, judge_score: nil) if question.out_of_corpus?

      reciprocal_rank = Metrics.reciprocal_rank(retrieved_contents, question.markers)
      base.merge(
        hit: reciprocal_rank.positive?,
        reciprocal_rank: reciprocal_rank,
        judge_score: judge_score(question, answer)
      )
    end

    # Grade a generated answer against the reference. An abstention (or no answer,
    # when judging is off) is not graded: nil drops out of the mean.
    def judge_score(question, answer)
      return nil if answer.nil? || answer == AnswerGenerator::ABSTAIN_MESSAGE

      Judge.new(
        question: question.text,
        reference_answer: question.reference_answer,
        generated_answer: answer,
        samples: @samples
      ).call[:score]
    end

    # The model phrases a refusal in its own words ("I don't know") — which the
    # grounding prompt (AnswerGenerator::SYSTEM_PROMPT) explicitly instructs — so
    # an exact match on the canned floor message under-counts abstention and reads
    # a correct decline as a fabrication. Detect the refusal the prompt induces.
    REFUSAL = /\bi\s+do\s?n['’]?t\s+know\b/i

    def declined?(retrieval, answer)
      retrieval.abstained? || answer == AnswerGenerator::ABSTAIN_MESSAGE || REFUSAL.match?(answer.to_s)
    end

    def generate_answer(question, retrieval, tenant)
      conversation = tenant.conversations.create!(title: "[eval] #{question.id}")
      message = conversation.messages.create!(role: :assistant, content: "")
      AnswerGenerator.new(message: message, question: question.text, retrieval: retrieval).call
    end

    def backend_name
      LlmClient.backend.class.name
    end
  end
end
