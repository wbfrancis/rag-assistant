# Turns raw document bytes into clean UTF-8 text, keyed by content type.
# Fails loudly when extraction yields too little usable text, so the ingestor
# can mark the document failed instead of embedding garbage.
#
# Thin slice: text/plain, text/markdown, text/html only. PDF (pdf-reader) is
# deferred.
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
      else
        raise UnsupportedContentTypeError, "Unsupported content type: #{content_type.inspect}"
      end

    text = text.scrub.strip

    if text.length < MIN_CHARS || printable_ratio(text) < MIN_PRINTABLE_RATIO
      raise LowYieldError, "Extracted text too short or low-quality (#{text.length} chars)."
    end

    text
  end

  def self.printable_ratio(text)
    return 0.0 if text.empty?

    printable = text.each_char.count { |c| c.match?(/[[:print:][:space:]]/) }
    printable.to_f / text.length
  end
end
