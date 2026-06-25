# frozen_string_literal: true

require "json"

module Eval
  # LLM-as-judge (RAG_ASSISTANT_ARCHITECTURE.md §9): grade a generated answer
  # against a reference on faithfulness + relevance, 1–5. This metric is
  # explicitly *directional* — it is non-deterministic, costs live API calls, and
  # has known biases (length, self-preference) — so the harness reports it but
  # does not CI-gate on it (ADR 0005, decision 4).
  #
  # Calls LlmClient.stream_chat with **no block**, which returns the full string
  # (see app/services/llm_client.rb), and parses a JSON verdict defensively: a
  # malformed grade yields a nil score (excluded from the mean) rather than
  # crashing a run. With +samples > 1+ it averages several grades to reduce flap.
  class Judge
    SCALE_MIN = 1
    SCALE_MAX = 5

    SYSTEM_PROMPT = <<~PROMPT.strip
      You are a strict grader of answers produced by a retrieval-augmented system.
      Compare the CANDIDATE answer to the REFERENCE answer for the QUESTION and
      grade it on an integer scale from 1 to 5 for faithfulness and relevance:
      - 5 = faithful to the reference and fully answers the question
      - 3 = partially correct or incomplete
      - 1 = wrong, irrelevant, or fabricated
      Respond with ONLY a JSON object: {"score": <1-5>, "rationale": "<one sentence>"}.
    PROMPT

    def initialize(question:, reference_answer:, generated_answer:, samples: 1)
      @question = question.to_s
      @reference_answer = reference_answer.to_s
      @generated_answer = generated_answer.to_s
      @samples = [ samples.to_i, 1 ].max
    end

    # @return [Hash] { score: Float|nil, rationale: String|nil, raw: Array<String> }
    def call
      raws = Array.new(@samples) { LlmClient.stream_chat(messages) }
      verdicts = raws.map { |raw| parse(raw) }

      {
        score: Metrics.mean(verdicts.map { |v| v[:score] }),
        rationale: verdicts.map { |v| v[:rationale] }.compact.first,
        raw: raws
      }
    end

    private

    def messages
      [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: user_content }
      ]
    end

    def user_content
      <<~CONTENT.strip
        QUESTION:
        #{@question}

        REFERENCE answer:
        #{@reference_answer}

        CANDIDATE answer:
        #{@generated_answer}
      CONTENT
    end

    # Defensive: try strict JSON, then the first {...} blob in the text; on any
    # failure return a nil score so a flaky judge can't crash the run.
    def parse(raw)
      data = parse_json(raw)
      return { score: nil, rationale: nil } unless data.is_a?(Hash)

      { score: clamp_score(data["score"] || data[:score]), rationale: data["rationale"] || data[:rationale] }
    end

    def parse_json(raw)
      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      blob = raw.to_s[/\{.*\}/m]
      blob && (JSON.parse(blob) rescue nil)
    end

    def clamp_score(value)
      return nil unless value.is_a?(Numeric) || value.to_s.match?(/\A\s*\d+\s*\z/)

      value.to_i.clamp(SCALE_MIN, SCALE_MAX)
    end
  end
end
