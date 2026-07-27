require "rails_helper"

RSpec.describe MessagesHelper, type: :helper do
  let(:citation) do
    {
      "chunk_id" => 456,
      "document_id" => 123,
      "document_title" => "Retrieval notes",
      "position" => 2,
      "excerpt" => "Hybrid retrieval combines dense and lexical search."
    }
  end

  def assistant(content:, citations: [ citation ])
    build(
      :message,
      :assistant,
      content: content,
      citations: citations,
      retrieval_scores: { "456" => 0.88 }
    )
  end

  it "renders structured Markdown and inline citations" do
    message = assistant(content: <<~MARKDOWN)
      Retrieval has two stages:

      1. **Search:** Find dense and lexical matches [1].
      2. **Fusion:** Combine their rankings.
    MARKDOWN

    html = helper.assistant_body(message)

    expect(html).to include("<ol>")
    expect(html).to include("<strong>Search:</strong>")
    expect(html).to include("class=\"cite-chip\"")
    expect(html).to include("/documents/123")
    expect(html).not_to include("**")
    expect(html).not_to include("msg-sources")
  end

  it "removes model-authored HTML and links" do
    message = assistant(
      content: "<script>alert('x')</script>\n\n[unsafe](javascript:alert('x')) [1]"
    )

    html = helper.assistant_body(message)

    expect(html).not_to include("<script")
    expect(html).not_to include("javascript:")
    expect(html.scan("<a ").length).to eq(1)
    expect(html).to include("class=\"cite-chip\"")
  end

  it "separates sources from prose when an older answer has no inline markers" do
    html = helper.assistant_body(assistant(content: "A legacy answer without a marker."))

    expect(html).to include("msg-sources")
    expect(html).to include(">sources<")
    expect(html).to include("class=\"cite-chip\"")
  end
end
