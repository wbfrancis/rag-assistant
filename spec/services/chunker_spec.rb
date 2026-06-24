require "rails_helper"

RSpec.describe Chunker do
  let(:encoder) { Tiktoken.get_encoding(Chunker::ENCODING) }

  def token_count(text)
    encoder.encode(text).length
  end

  it "returns chunk hashes with sequential positions and the expected keys" do
    chunks = Chunker.call("Para one.\n\nPara two.\n\nPara three.")

    expect(chunks).to be_an(Array)
    expect(chunks.map { |c| c[:position] }).to eq((0...chunks.length).to_a)
    expect(chunks.first.keys).to include(:content, :position, :token_count, :content_hash, :metadata)
  end

  it "reports accurate tiktoken token counts (not a chars/4 estimate)" do
    chunks = Chunker.call("The quick brown fox jumps over the lazy dog.")

    chunks.each do |chunk|
      expect(chunk[:token_count]).to eq(token_count(chunk[:content]))
    end
  end

  it "produces deterministic content hashes across runs" do
    text  = "Stable input.\n\nAnother paragraph that should hash identically every time."
    first  = Chunker.call(text)
    second = Chunker.call(text)

    expect(first.map { |c| c[:content_hash] }).to eq(second.map { |c| c[:content_hash] })
  end

  it "keeps chunks within the token budget" do
    text   = Array.new(120) { |i| "Sentence #{i} carries a unique marker word zeta#{i} along with it." }.join(" ")
    chunks = Chunker.call(text, target_tokens: 120, max_tokens: 160, overlap_ratio: 0.125)

    expect(chunks.length).to be > 1
    # Body packs to ~target; overlap adds at most the overlap budget on top.
    expect(chunks).to all(satisfy { |c| c[:token_count] <= 160 + (120 * 0.125).round })
  end

  it "overlaps adjacent chunks so a boundary marker appears in both" do
    text   = Array.new(120) { |i| "Sentence #{i} carries a unique marker word zeta#{i} along with it." }.join(" ")
    chunks = Chunker.call(text, target_tokens: 120, max_tokens: 160, overlap_ratio: 0.15)

    expect(chunks.length).to be > 1
    shares_marker = chunks.each_cons(2).all? do |a, b|
      (a[:content].scan(/zeta\d+/) & b[:content].scan(/zeta\d+/)).any?
    end
    expect(shares_marker).to be(true)
  end

  it "produces disjoint chunks when overlap is disabled" do
    text   = Array.new(120) { |i| "Sentence #{i} carries a unique marker word zeta#{i} along with it." }.join(" ")
    chunks = Chunker.call(text, target_tokens: 120, max_tokens: 160, overlap_ratio: 0)

    disjoint = chunks.each_cons(2).all? do |a, b|
      (a[:content].scan(/zeta\d+/) & b[:content].scan(/zeta\d+/)).empty?
    end
    expect(disjoint).to be(true)
  end

  it "starts a new chunk at a markdown heading" do
    text = "# Intro\n\nIntro paragraph one with a little body.\n\n" \
           "## Section Two\n\nSecond section body text here."
    chunks = Chunker.call(text, overlap_ratio: 0)

    section_chunk = chunks.find { |c| c[:content].include?("## Section Two") }
    expect(section_chunk).to be_present
    expect(section_chunk[:content]).not_to include("# Intro")
  end

  it "hard-splits a whitespace-free blob that exceeds the token budget" do
    big    = "x" * 20_000
    chunks = Chunker.call(big, target_tokens: 100, max_tokens: 100, overlap_ratio: 0)

    expect(chunks.length).to be > 1
    expect(chunks).to all(satisfy { |c| token_count(c[:content]) <= 100 })
  end
end
