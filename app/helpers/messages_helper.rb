module MessagesHelper
  CITATION_PATTERN = /\[(\d+)\]/

  # The assistant bubble's body: a typing indicator while the answer is still
  # streaming in (content blank), otherwise the answer text with any inline
  # "[n]" markers turned into clickable citation chips.
  def assistant_body(message, active_chunk_id: nil)
    return typing_indicator if message.content.blank?

    safe_join(citation_segments(message, active_chunk_id))
  end

  # One line of retrieval/generation transparency under a finished answer:
  # how it was retrieved, how many chunks grounded it, how long it took, what
  # it cost — or, for an abstention, why it declined to answer at all.
  def message_trace(message)
    return nil if message.content.blank?

    message.citations.present? ? answer_trace(message) : abstain_trace(message)
  end

  private

  def typing_indicator
    content_tag(:span, class: "msg-typing") do
      safe_join(Array.new(3) { content_tag(:span, "▮") })
    end
  end

  # Splits the answer into plain text and citation-chip segments. The model is
  # asked (AnswerGenerator::SYSTEM_PROMPT) to cite inline as "[n]", using the
  # same numbering as `message.citations`. Any citation it never mentions
  # inline — or a backend that never emits bracket markers at all — is
  # appended as a trailing chip, so a source is never silently dropped.
  def citation_segments(message, active_chunk_id)
    citations = message.citations || []
    used = []
    segments = []

    message.content.split(CITATION_PATTERN).each_with_index do |part, i|
      if i.odd?
        citation = citations[part.to_i - 1]
        if citation
          used << part.to_i - 1
          segments << citation_chip(message, citation, part.to_i, active_chunk_id)
        else
          segments << "[#{part}]"
        end
      elsif part.present?
        segments << part
      end
    end

    citations.each_with_index do |citation, i|
      next if used.include?(i)

      segments << " " if segments.present?
      segments << citation_chip(message, citation, i + 1, active_chunk_id)
    end

    segments
  end

  def citation_chip(message, citation, n, active_chunk_id)
    chunk_id = citation["chunk_id"]
    active = active_chunk_id.present? && active_chunk_id.to_s == chunk_id.to_s

    link_to "[#{n}]",
      document_path(citation["document_id"], chunk_id: chunk_id, sim: similarity_pct(message, chunk_id)),
      class: [ "cite-chip", ("is-active" if active) ].compact.join(" "),
      data: { turbo_frame: "doc_pane", reading_room_target: "chip", chunk_id: chunk_id }
  end

  def similarity_pct(message, chunk_id)
    similarity = message.retrieval_scores.to_h[chunk_id.to_s]
    return nil unless similarity

    (similarity * 100).round
  end

  def answer_trace(message)
    mode = "dense∪lexical → rrf"
    mode += " + rerank" if Reranker.enabled?
    cost = message.cost ? format("$%.4f", message.cost) : "—"

    "#{mode} · #{pluralize(message.citations.size, "chunk")} · #{message.latency_ms}ms · #{cost}"
  end

  def abstain_trace(message)
    if message.top_similarity
      "top sim #{format('%.2f', message.top_similarity)} < floor #{format('%.2f', Retriever::RELEVANCE_FLOOR)} → abstained · #{message.latency_ms}ms"
    else
      "no matching context → abstained · #{message.latency_ms}ms"
    end
  end
end
