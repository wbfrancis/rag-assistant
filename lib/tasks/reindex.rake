# frozen_string_literal: true

# Rolling embedding-model re-index (ADR 0006).
#
#   bin/rails reindex:status                                  # counts per embedding_model
#   bin/rails reindex:backfill                                # re-embed to the configured model
#   TARGET_MODEL=text-embedding-3-large bin/rails reindex:backfill
#
# Backfill re-embeds only chunks not already at the target model; it is
# idempotent and resumable. After it completes, validate with `rake eval`, then
# point LLM_EMBEDDING_MODEL at the new model to cut the Retriever over. The
# heavy lifting lives in Reindexer so it can be unit-tested with the Fake.

namespace :reindex do
  desc "Show chunk counts grouped by embedding_model"
  task status: :environment do
    Reindexer.new.status.sort_by { |model, _| model.to_s }.each do |model, count|
      puts format("%-30s %d", model || "(none)", count)
    end
  end

  desc "Re-embed chunks not at TARGET_MODEL (default = the configured embedding model)"
  task backfill: :environment do
    target = ENV.fetch("TARGET_MODEL", LlmClient.config.embedding_model)
    puts "Backfilling chunks to #{target}…"
    count = Reindexer.new(target_model: target).backfill
    puts "Re-embedded #{count} chunk(s)."
    puts "Validate with `rake eval`, then set LLM_EMBEDDING_MODEL=#{target} to cut the Retriever over."
  end
end
