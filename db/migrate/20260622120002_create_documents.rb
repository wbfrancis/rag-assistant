class CreateDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :documents, id: :uuid do |t|
      # tenant_id is the owning user. null: false enforces tenancy at the DB level.
      t.references :tenant, type: :uuid, null: false,
                            foreign_key: { to_table: :users }, index: true
      t.string :title, null: false
      t.string :source_uri
      t.string :content_type, null: false
      t.text :raw_text                 # pasted text or the uploaded file's contents
      t.string :content_hash           # fingerprint of extracted text (idempotency)
      t.integer :status, null: false, default: 0
      t.datetime :processed_at
      t.text :error_message

      t.timestamps
    end

    add_index :documents, :content_hash
  end
end
