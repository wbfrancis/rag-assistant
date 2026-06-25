class CreateConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :conversations, id: :uuid do |t|
      # tenant_id is the owning user. null: false enforces tenancy at the DB level,
      # same as documents/chunks.
      t.references :tenant, type: :uuid, null: false,
                            foreign_key: { to_table: :users }, index: true
      t.string :title   # derived from the first question; nullable

      t.timestamps
    end
  end
end
