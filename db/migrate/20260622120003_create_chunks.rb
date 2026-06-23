class CreateChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :chunks, id: :uuid do |t|
      t.references :document, type: :uuid, null: false, foreign_key: true, index: true
      # tenant_id is denormalized from the parent document so every later query
      # can filter by tenant without a join.
      t.references :tenant, type: :uuid, null: false,
                            foreign_key: { to_table: :users }, index: true
      t.integer :position, null: false
      t.text :content, null: false
      t.string :content_hash
      t.integer :token_count
      t.column :embedding, "vector(1536)"   # pgvector column, fixed at 1536 dims
      t.string :embedding_model
      t.integer :embedding_dim
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :chunks, :content_hash
    add_index :chunks, :embedding_model

    # HNSW index with cosine distance — fast approximate nearest-neighbor search,
    # matching the Retriever built in Phase 2.
    add_index :chunks, :embedding, using: :hnsw, opclass: :vector_cosine_ops
  end
end
