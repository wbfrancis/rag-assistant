class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages, id: :uuid do |t|
      t.references :conversation, type: :uuid, null: false, foreign_key: true, index: true
      t.integer :role, null: false, default: 0          # enum: user / assistant
      t.text :content, null: false, default: ""         # assistant starts blank, filled as it streams

      # Which chunks grounded an assistant answer (powers debugging + live links).
      t.uuid :chunk_ids, array: true, null: false, default: []
      # Durable citation snapshot so historical answers survive re-ingest/delete
      # of the underlying chunks (ADR 0004).
      t.jsonb :citations, null: false, default: []

      # Generation metadata (assistant messages).
      t.string :model
      t.integer :prompt_tokens
      t.integer :completion_tokens
      t.integer :latency_ms
      t.jsonb :retrieval_scores   # { chunk_id => similarity }, for debugging

      t.timestamps
    end
  end
end
