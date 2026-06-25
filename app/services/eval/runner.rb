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

      base = {
        id: question.id,
        question: question.text,
        out_of_corpus: question.out_of_corpus?,
        abstained: retrieval.abstained?,
        retrieved_count: retrieved_contents.size
      }

      return base.merge(hit: nil, reciprocal_rank: nil, judge_score: nil) if question.out_of_corpus?

      reciprocal_rank = Metrics.reciprocal_rank(retrieved_contents, question.markers)
      base.merge(
        hit: reciprocal_rank.positive?,
        reciprocal_rank: reciprocal_rank,
        judge_score: (@judge ? judge_score(question, retrieval, tenant) : nil)
      )
    end

    # Generate the answer via the real production path, then grade it. An
    # abstention is not graded (there is no answer to judge): nil drops out of the
    # mean.
    def judge_score(question, retrieval, tenant)
      answer = generate_answer(question, retrieval, tenant)
      return nil if answer == AnswerGenerator::ABSTAIN_MESSAGE

      Judge.new(
        question: question.text,
        reference_answer: question.reference_answer,
        generated_answer: answer,
        samples: @samples
      ).call[:score]
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
