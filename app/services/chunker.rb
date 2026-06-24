require "digest"
require "tiktoken_ruby"

# Splits text into overlapping, token-budgeted chunks for embedding.
#
# Strategy (see docs/adr/0001-chunking-strategy.md):
#   * Token counts come from tiktoken (cl100k_base), matching the OpenAI
#     embedding tokenizer, instead of the old chars/4 heuristic.
#   * We pack along *structural* boundaries -- paragraphs first, then sentences,
#     then a hard token-window split -- so a chunk rarely cuts mid-thought.
#   * A markdown heading starts a new chunk so a section's heading travels with
#     its body.
#   * Consecutive chunks share ~OVERLAP_RATIO of trailing tokens so a fact that
#     straddles a boundary is still retrievable from at least one chunk.
#
# +content_hash+ is a deterministic SHA-256 of the (overlap-inclusive) chunk
# content, so unchanged input always yields identical hashes -- the diff-based
# reconciler in DocumentIngestor relies on this.
class Chunker
  TARGET_TOKENS = 600
  MAX_TOKENS    = 800
  OVERLAP_RATIO = 0.125
  ENCODING      = "cl100k_base"

  HEADING = /\A\#{1,6}\s/

  def self.call(text, **opts)
    new(**opts).call(text)
  end

  def initialize(target_tokens: TARGET_TOKENS, max_tokens: MAX_TOKENS, overlap_ratio: OVERLAP_RATIO)
    @target_tokens = target_tokens
    @max_tokens    = max_tokens
    @overlap_ratio = overlap_ratio
  end

  def call(text)
    chunks = pack(atomize(text.to_s))
    finalize(chunks)
  end

  private

  def encoder
    @encoder ||= Tiktoken.get_encoding(ENCODING)
  end

  def count(text)
    encoder.encode(text).length
  end

  # Break text into the smallest units we are willing to keep whole -- paragraphs,
  # falling back to sentences, then fixed token windows -- so every atom fits the
  # max-token budget. Each atom records whether it is a heading.
  def atomize(text)
    paragraphs(text).flat_map do |para|
      heading = para.match?(HEADING)
      if count(para) <= @max_tokens
        [ atom(para, heading) ]
      else
        sentences(para).flat_map do |sentence|
          if count(sentence) <= @max_tokens
            [ atom(sentence, false) ]
          else
            hard_split(sentence).map { |piece| atom(piece, false) }
          end
        end
      end
    end
  end

  def paragraphs(text)
    text.split(/\n{2,}/).map(&:strip).reject(&:empty?)
  end

  def sentences(text)
    text.split(/(?<=[.!?])\s+/).map(&:strip).reject(&:empty?)
  end

  # Last resort: a single "sentence" longer than the budget (e.g. a giant
  # whitespace-free blob). Slice the token stream into max-token windows and
  # decode each window back to text.
  def hard_split(text)
    encoder.encode(text).each_slice(@max_tokens).map { |slice| encoder.decode(slice) }
  end

  def atom(text, heading)
    { text: text, tokens: count(text), heading: heading }
  end

  # Greedily combine atoms into chunks (arrays of atoms), starting a new chunk
  # when the target budget would be exceeded, or when a heading arrives and the
  # current chunk already holds content.
  def pack(atoms)
    chunks  = []
    current = []
    tokens  = 0

    atoms.each do |a|
      break_here = (tokens + a[:tokens] > @target_tokens) || (a[:heading] && tokens.positive?)

      if break_here && !current.empty?
        chunks << current
        current = []
        tokens  = 0
      end

      current << a
      tokens  += a[:tokens]
    end

    chunks << current unless current.empty?
    chunks
  end

  def finalize(chunks)
    bodies = chunks.map { |atoms| atoms.map { |a| a[:text] }.join("\n\n") }
    budget = (@target_tokens * @overlap_ratio).round

    bodies.each_with_index.map do |body, index|
      overlap = index.zero? ? "" : overlap_for(bodies[index - 1], budget)
      content = overlap.empty? ? body : "#{overlap}\n\n#{body}"
      content = content.strip

      {
        content: content,
        position: index,
        token_count: count(content),
        content_hash: Digest::SHA256.hexdigest(content),
        metadata: {}
      }
    end
  end

  # Trailing slice of the previous chunk -- whole sentences, newest first, up to
  # the overlap token budget -- so adjacent chunks share context.
  def overlap_for(previous_body, budget)
    return "" if budget.zero?

    taken  = []
    tokens = 0
    sentences(previous_body).reverse_each do |sentence|
      t = count(sentence)
      break if tokens + t > budget && !taken.empty?

      taken.unshift(sentence)
      tokens += t
      break if tokens >= budget
    end
    taken.join(" ")
  end
end
