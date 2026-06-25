# frozen_string_literal: true

module Eval
  # One evaluation case.
  #
  # An *answerable* question names the source(s) that should ground its answer by
  # +expected_markers+ — short substrings that the correct chunk's content must
  # contain. We match on content, not chunk id, on purpose: chunk ids and
  # boundaries change every time you re-chunk, which is exactly the change the
  # harness exists to measure, so pinning gold to ids would break the metric on
  # the change under test (ADR 0005, decision 1).
  #
  # An *out-of-corpus* question (+out_of_corpus: true+, no markers) is an
  # abstention case: the system must decline rather than fabricate.
  Question = Struct.new(:id, :text, :expected_markers, :reference_answer, :out_of_corpus, keyword_init: true) do
    def out_of_corpus?
      !!out_of_corpus
    end

    def markers
      Array(expected_markers)
    end
  end
end
