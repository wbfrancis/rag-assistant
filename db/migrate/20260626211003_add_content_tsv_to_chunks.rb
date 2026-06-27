# frozen_string_literal: true

# Hybrid search (ADR 0007): give chunks a lexical index alongside the dense
# pgvector embedding. +content_tsv+ is a Postgres GENERATED ... STORED column —
# the database derives it from +content+ on every write, so it can never drift
# out of sync with the text it indexes (the same "derive, don't store" stance as
# the generated/denormalized columns in ADR 0001/0006). A GIN index makes the
# +content_tsv @@ plainto_tsquery(...)+ leg of the Retriever fast.
class AddContentTsvToChunks < ActiveRecord::Migration[8.1]
  def change
    add_column :chunks, :content_tsv, :virtual,
               type: :tsvector,
               as: "to_tsvector('english', content)",
               stored: true

    add_index :chunks, :content_tsv, using: :gin, name: "index_chunks_on_content_tsv"
  end
end
