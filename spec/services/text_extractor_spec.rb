require "rails_helper"

RSpec.describe TextExtractor do
  it "reads plain text as UTF-8" do
    text = TextExtractor.call(content_type: "text/plain", data: "Hello, this is plain text content.")
    expect(text).to include("plain text content")
  end

  it "keeps markdown as-is" do
    text = TextExtractor.call(content_type: "text/markdown", data: "# Heading\n\nSome body text here for testing.")
    expect(text).to include("# Heading").and include("body text")
  end

  it "extracts visible text from HTML, dropping scripts/styles" do
    html = "<html><head><style>.x{}</style></head>" \
           "<body><script>evil()</script><p>Visible content that is long enough.</p></body></html>"
    text = TextExtractor.call(content_type: "text/html", data: html)

    expect(text).to include("Visible content")
    expect(text).not_to include("evil()")
  end

  it "raises LowYieldError on too-short input" do
    expect { TextExtractor.call(content_type: "text/plain", data: "hi") }
      .to raise_error(TextExtractor::LowYieldError)
  end

  it "raises UnsupportedContentTypeError for unknown types" do
    expect { TextExtractor.call(content_type: "application/zip", data: "anything") }
      .to raise_error(TextExtractor::UnsupportedContentTypeError)
  end
end
