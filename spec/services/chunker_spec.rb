require "rails_helper"

RSpec.describe Chunker do
  it "returns chunk hashes with sequential positions" do
    text = "Para one.\n\nPara two.\n\nPara three."
    chunks = Chunker.call(text)

    expect(chunks).to be_an(Array)
    expect(chunks.map { |c| c[:position] }).to eq((0...chunks.length).to_a)
    expect(chunks.first.keys).to include(:content, :position, :token_count, :content_hash, :metadata)
  end

  it "produces deterministic content hashes across runs" do
    text = "Stable input.\n\nAnother paragraph that should hash identically every time."
    first = Chunker.call(text)
    second = Chunker.call(text)

    expect(first.map { |c| c[:content_hash] }).to eq(second.map { |c| c[:content_hash] })
  end

  it "hard-splits a paragraph that exceeds the character budget" do
    big = "x" * 5_000
    chunks = Chunker.call(big, target_chars: 1_000)

    expect(chunks.length).to be > 1
    expect(chunks).to all(satisfy { |c| c[:content].length <= 1_000 })
  end

  it "respects the character budget when packing paragraphs" do
    text = ([ "A paragraph of moderate length here." ] * 50).join("\n\n")
    chunks = Chunker.call(text, target_chars: 200)

    expect(chunks).to all(satisfy { |c| c[:content].length <= 300 })
  end
end
