class AddTopSimilarityToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :top_similarity, :float
  end
end
