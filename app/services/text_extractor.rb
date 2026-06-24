require "pdf/reader"
require "stringio"

# Turns raw document bytes into clean UTF-8 text, keyed by content type.
# Fails loudly when extraction yields too little usable text, so the ingestor
# can mark the document failed instead of embedding garbage.
#
# Supports text/plain, text/markdown, text/html and application/pdf. Image-only
# (scanned) PDFs yield almost no text and are caught by the low-yield guard.
class TextExtractor
  class Error < StandardError; end
  class LowYieldError < Error; end
  class UnsupportedContentTypeError < Error; end

  MIN_CHARS = 20
  MIN_PRINTABLE_RATIO = 0.6

  def self.call(content_type:, data:)
    text =
      case content_type
      when "text/plain", "text/markdown"
        data.to_s.dup.force_encoding("UTF-8")
      when "text/html"
        doc = Nokogiri::HTML(data.to_s)
        doc.css("script, style").remove
        doc.text
      when "application/pdf"
        extract_pdf(data)
      else
        raise UnsupportedContentTypeError, "Unsupported content type: #{content_type.inspect}"
      end

    text = text.scrub.strip

    if text.length < MIN_CHARS || printable_ratio(text) < MIN_PRINTABLE_RATIO
      raise LowYieldError, "Extracted text too short or low-quality (#{text.length} chars)."
    end

    text
  end

  # Concatenate the text layer of every page. A malformed PDF raises a
  # PDF::Reader error, which we surface as a permanent extraction failure.
  def self.extract_pdf(data)
    reader = PDF::Reader.new(StringIO.new(data.to_s))
    reader.pages.map(&:text).join("\n\n")
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError => e
    raise Error, "Could not read PDF: #{e.message}"
  end

  def self.printable_ratio(text)
    return 0.0 if text.empty?

    printable = text.each_char.count { |c| c.match?(/[[:print:][:space:]]/) }
    printable.to_f / text.length
  end
end
