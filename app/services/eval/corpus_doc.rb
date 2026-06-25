# frozen_string_literal: true

module Eval
  # One source document in an eval fixture corpus: a title and a body of text the
  # harness ingests through the real pipeline (CorpusSeeder -> DocumentIngestor).
  CorpusDoc = Struct.new(:title, :body, keyword_init: true)
end
