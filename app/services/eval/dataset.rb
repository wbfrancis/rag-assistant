# frozen_string_literal: true

require "yaml"

module Eval
  # Loads and validates an eval fixture set from a directory holding +corpus.yml+
  # (the source documents) and +questions.yml+ (the cases). Validation fails loud
  # and early: a marker that appears in no corpus body — or a missing reference
  # answer — is almost always a fixture typo, and a silent 0-recall result would
  # hide it.
  class Dataset
    class InvalidError < StandardError; end

    attr_reader :corpus, :questions

    def self.load(dir:)
      dir = dir.to_s
      corpus    = read(File.join(dir, "corpus.yml")).map { |row| build_doc(row) }
      questions = read(File.join(dir, "questions.yml")).map { |row| build_question(row) }
      new(corpus: corpus, questions: questions).tap(&:validate!)
    end

    # Map fixture keys explicitly so the YAML schema (which reads naturally:
    # "question:", "body:") is decoupled from the struct members.
    def self.build_doc(row)
      CorpusDoc.new(title: row[:title], body: row[:body])
    end

    def self.build_question(row)
      Question.new(
        id: row[:id],
        text: row[:question],
        expected_markers: row[:expected_markers],
        reference_answer: row[:reference_answer],
        out_of_corpus: row[:out_of_corpus]
      )
    end

    def self.read(path)
      raise InvalidError, "Missing fixture file: #{path}" unless File.exist?(path)

      Array(YAML.safe_load_file(path, symbolize_names: true))
    end

    def initialize(corpus:, questions:)
      @corpus = corpus
      @questions = questions
    end

    def validate!
      raise InvalidError, "Corpus is empty" if corpus.empty?
      raise InvalidError, "No questions" if questions.empty?

      bodies = corpus.map(&:body).join("\n")
      questions.each { |question| validate_question!(question, bodies) }
      self
    end

    private

    def validate_question!(question, bodies)
      raise InvalidError, "Question missing id" if question.id.to_s.strip.empty?
      raise InvalidError, "Question #{question.id} missing text" if question.text.to_s.strip.empty?
      return if question.out_of_corpus?

      if question.markers.empty?
        raise InvalidError, "Answerable question #{question.id} has no expected_markers"
      end
      if question.reference_answer.to_s.strip.empty?
        raise InvalidError, "Answerable question #{question.id} has no reference_answer"
      end

      missing = question.markers.reject { |marker| bodies.include?(marker.to_s) }
      return if missing.empty?

      raise InvalidError, "Question #{question.id} has markers absent from the corpus: #{missing.inspect}"
    end
  end
end
