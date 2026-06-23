require "digest"

# Splits text into chunks for embedding. Thin slice: pack paragraphs up to a
# character budget, hard-splitting any oversized paragraph. (The structure-aware
# tiktoken-based chunker with token budgets + overlap is deferred.)
class Chunker
  TARGET_CHARS = 1_500

  def self.call(text, target_chars: TARGET_CHARS)
    paragraphs = text.to_s.split(/\n{2,}/).map(&:strip).reject(&:empty?)

    packed = []
    buffer = +""
    paragraphs.each do |para|
      if buffer.empty?
        buffer = para.dup
      elsif buffer.length + para.length + 2 <= target_chars
        buffer << "\n\n" << para
      else
        packed << buffer
        buffer = para.dup
      end
    end
    packed << buffer unless buffer.strip.empty?

    packed = packed.flat_map do |chunk|
      chunk.length > target_chars * 1.5 ? hard_split(chunk, target_chars) : [ chunk ]
    end

    packed.each_with_index.map do |content, index|
      content = content.strip
      {
        content: content,
        position: index,
        token_count: estimate_tokens(content),
        content_hash: Digest::SHA256.hexdigest(content),
        metadata: {}
      }
    end
  end

  def self.hard_split(text, size)
    text.scan(/.{1,#{size}}/m).map(&:strip).reject(&:empty?)
  end

  # Rough heuristic (~4 chars/token) until tiktoken_ruby is wired in.
  def self.estimate_tokens(text)
    (text.length / 4.0).ceil
  end
end
