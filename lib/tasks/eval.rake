# frozen_string_literal: true

# Offline evaluation harness (ADR 0005).
#
#   bin/rails eval                 # retrieval + abstention + LLM judge (JUDGE=true)
#   bin/rails eval:retrieval       # retrieval + abstention only (fast, no judge)
#
# ENV knobs: DIR, K, MIN_SIMILARITY (sweep the relevance floor here), JUDGE,
# SAMPLES, HYBRID (default true — dense+lexical RRF; set false for the dense
# baseline), RERANK (default false — LLM second stage), FORMAT=json (write
# tmp/eval/report-<ts>.json), and the CI gate thresholds MIN_RECALL / MIN_MRR /
# MIN_ABSTENTION (exit non-zero if unmet). The dense → hybrid → hybrid+rerank
# sweep is run with HYBRID/RERANK; that comparison is the README headline table.
# Uses whatever LlmClient backend is configured — the real model when a key is
# present (semantic signal), the Fake otherwise (deterministic plumbing check).

desc "Run the full evaluation harness (retrieval + abstention + LLM judge when JUDGE=true)"
task eval: :environment do
  run_eval(judge: ENV.fetch("JUDGE", "false") == "true")
end

namespace :eval do
  desc "Run retrieval + abstention metrics only (no LLM judge)"
  task retrieval: :environment do
    run_eval(judge: false)
  end
end

def run_eval(judge:)
  dataset = Eval::Dataset.load(dir: ENV.fetch("DIR", Rails.root.join("spec/fixtures/eval").to_s))

  report = Eval::Runner.new(
    dataset: dataset,
    k: Integer(ENV.fetch("K", 8)),
    min_similarity: Float(ENV.fetch("MIN_SIMILARITY", Retriever::RELEVANCE_FLOOR)),
    judge: judge,
    samples: Integer(ENV.fetch("SAMPLES", 1)),
    hybrid: ENV.fetch("HYBRID", "true") != "false",
    rerank: ENV.fetch("RERANK", "false") == "true"
  ).call

  puts report.to_table
  write_json(report) if ENV["FORMAT"] == "json"
  enforce_thresholds(report)
end

def write_json(report)
  dir = Rails.root.join("tmp/eval")
  FileUtils.mkdir_p(dir)
  path = dir.join("report-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.json")
  File.write(path, report.to_json)
  puts "\nWrote #{path}"
end

def enforce_thresholds(report)
  thresholds = {}
  thresholds[:recall_at_k]         = Float(ENV["MIN_RECALL"])     if ENV["MIN_RECALL"]
  thresholds[:mrr]                 = Float(ENV["MIN_MRR"])        if ENV["MIN_MRR"]
  thresholds[:abstention_accuracy] = Float(ENV["MIN_ABSTENTION"]) if ENV["MIN_ABSTENTION"]
  return if report.meets?(thresholds)

  warn "\nEval thresholds not met: #{report.failures(thresholds).join('; ')}"
  exit(1)
end
