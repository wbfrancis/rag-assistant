# frozen_string_literal: true

module Eval
  # The deterministic core of the harness: pure functions over plain data, no DB
  # and no LLM, so they can be exhaustively unit-tested. Retrieval quality is
  # scored by whether a gold *marker* appears among the
  # chunks the Retriever surfaced, and where.
  #
  # Note on recall@k: the Retriever is already called with +k+, so the list of
  # retrieved contents handed in here is the top-k. "Does any retrieved chunk
  # contain a marker" is therefore inherently hit@k, and the rank of the first
  # such chunk is its rank within the top-k.
  module Metrics
    module_function

    def contains_marker?(content, markers)
      Array(markers).any? { |marker| content.to_s.include?(marker.to_s) }
    end

    # 1-based rank of the first retrieved chunk containing a marker, or nil if
    # none of the top-k chunks match.
    def first_hit_rank(retrieved_contents, markers)
      retrieved_contents.each_with_index do |content, index|
        return index + 1 if contains_marker?(content, markers)
      end
      nil
    end

    # 1 / rank of the first hit (so a top-ranked hit scores 1.0, a rank-2 hit
    # 0.5, …), or 0.0 when the gold source never appears in the top-k.
    def reciprocal_rank(retrieved_contents, markers)
      rank = first_hit_rank(retrieved_contents, markers)
      rank ? 1.0 / rank : 0.0
    end

    # Mean of the present (non-nil) values, or nil when there are none — so an
    # empty/absent metric reads as "n/a" rather than a misleading 0.
    def mean(values)
      present = Array(values).compact
      return nil if present.empty?

      present.sum.to_f / present.size
    end
  end
end
