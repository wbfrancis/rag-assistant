# frozen_string_literal: true

require "json"

module Eval
  # The outcome of one evaluation run: per-question rows plus an aggregate
  # summary, rendered as a human table, a JSON artifact for diffing runs, and a
  # threshold check the rake task turns into a CI exit code (ADR 0005, decision 6).
  class Report
    METRIC_LABELS = {
      recall_at_k: "recall@k",
      mrr: "MRR",
      abstention_accuracy: "abstention accuracy",
      mean_judge: "mean judge score"
    }.freeze

    attr_reader :rows, :k, :min_similarity, :backend, :judged, :hybrid, :rerank

    def initialize(rows:, k:, min_similarity:, backend:, judged:, hybrid: nil, rerank: nil)
      @rows = rows
      @k = k
      @min_similarity = min_similarity
      @backend = backend
      @judged = judged
      @hybrid = hybrid
      @rerank = rerank
    end

    def summary
      @summary ||= begin
        answerable = rows.reject { |row| row[:out_of_corpus] }
        out_of_corpus = rows.select { |row| row[:out_of_corpus] }

        {
          questions: rows.size,
          answerable: answerable.size,
          out_of_corpus: out_of_corpus.size,
          recall_at_k: Metrics.mean(answerable.map { |row| row[:hit] ? 1.0 : 0.0 }),
          mrr: Metrics.mean(answerable.map { |row| row[:reciprocal_rank] }),
          abstention_accuracy: Metrics.mean(out_of_corpus.map { |row| row[:abstained] ? 1.0 : 0.0 }),
          mean_judge: Metrics.mean(answerable.map { |row| row[:judge_score] })
        }
      end
    end

    # Human label for the retrieval configuration under test: "dense", "hybrid",
    # or "hybrid+rerank". nil hybrid/rerank (e.g. a Report built directly in a
    # unit test) reads as "n/a" so the field is always present.
    def retrieval_mode
      return "n/a" if hybrid.nil?

      base = hybrid ? "hybrid" : "dense"
      rerank ? "#{base}+rerank" : base
    end

    def to_h
      {
        meta: { k: k, min_similarity: min_similarity, backend: backend, judged: judged, retrieval: retrieval_mode },
        summary: summary,
        rows: rows
      }
    end

    def to_json(*_args)
      JSON.pretty_generate(to_h)
    end

    # Which thresholds (a hash like { recall_at_k: 0.8 }) the run failed: a metric
    # below its threshold, or absent (nil) when a threshold demands it.
    def failures(thresholds)
      thresholds.filter_map do |metric, minimum|
        value = summary[metric]
        next if value && value >= minimum

        "#{METRIC_LABELS.fetch(metric, metric)} #{format_value(value)} < #{format('%.2f', minimum)}"
      end
    end

    def meets?(thresholds)
      failures(thresholds).empty?
    end

    def to_table
      lines = []
      lines << "RAG Evaluation Report"
      lines << "backend=#{backend}  retrieval=#{retrieval_mode}  k=#{k}  min_similarity=#{format('%.2f', min_similarity)}  judge=#{judged ? 'on' : 'off'}"
      lines << "questions=#{summary[:questions]} (answerable=#{summary[:answerable]}, out-of-corpus=#{summary[:out_of_corpus]})"
      lines << ("-" * 44)
      lines << format("%-22s %s", "Metric", "Value")
      METRIC_LABELS.each do |metric, label|
        lines << format("%-22s %s", label, format_value(summary[metric]))
      end
      lines.join("\n")
    end

    private

    def format_value(value)
      value.nil? ? "n/a" : format("%.2f", value)
    end
  end
end
