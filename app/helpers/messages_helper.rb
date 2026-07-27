require "commonmarker"
require "securerandom"

module MessagesHelper
  CITATION_PATTERN = /\[(\d+)\]/
  MARKDOWN_TAGS = %w[p br strong em ol ul li code pre blockquote h2 h3 h4 hr].freeze
  CITATION_TAGS = (MARKDOWN_TAGS + %w[a]).freeze
  CITATION_ATTRIBUTES = %w[
    href class data-turbo-frame data-reading-room-target data-chunk-id
  ].freeze

  # The assistant bubble's body: a typing indicator while the answer is still
  # streaming in (content blank), otherwise sanitized CommonMark with inline
  # "[n]" markers turned into application-generated citation chips.
  def assistant_body(message, active_chunk_id: nil)
    return typing_indicator if message.content.blank?

    rendered, used = render_markdown_with_citations(message, active_chunk_id)
    return rendered if used.present? || message.citations.blank?

    # Older/model-noncompliant answers can omit every inline marker. Keep their
    # sources reachable, but separate them from the prose instead of making a
    # pile of chips look like it supports the final sentence.
    safe_join([ rendered, fallback_sources(message, active_chunk_id) ])
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

  # Replace valid source markers with inert tokens before parsing Markdown. The
  # first sanitization removes model-authored HTML and links; after inserting
  # our own citation links, the second sanitization allows only their exact
  # attributes.
  def render_markdown_with_citations(message, active_chunk_id)
    citations = message.citations || []
    used = []
    token_prefix = "RAGCITATION#{SecureRandom.hex(8).upcase}"
    token_pattern = /#{Regexp.escape(token_prefix)}(\d+)TOKEN/

    markdown = message.content.gsub(CITATION_PATTERN) do |marker|
      index = Regexp.last_match(1).to_i - 1
      next marker unless citations[index]

      used << index
      "#{token_prefix}#{index}TOKEN"
    end

    html = Commonmarker.to_html(
      markdown.encode(Encoding::UTF_8),
      options: { render: { unsafe: false } }
    )
    clean_html = sanitize(html, tags: MARKDOWN_TAGS, attributes: [])
    with_chips = clean_html.gsub(token_pattern) do
      index = Regexp.last_match(1).to_i
      citation_chip(message, citations.fetch(index), index + 1, active_chunk_id).to_s
    end

    [
      sanitize(with_chips, tags: CITATION_TAGS, attributes: CITATION_ATTRIBUTES),
      used.uniq
    ]
  end

  def fallback_sources(message, active_chunk_id)
    chips = message.citations.each_with_index.map do |citation, index|
      citation_chip(message, citation, index + 1, active_chunk_id)
    end

    content_tag(:div, class: "msg-sources") do
      safe_join([
        content_tag(:span, "sources", class: "msg-sources-label"),
        safe_join(chips, " ")
      ])
    end
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
