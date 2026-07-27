require "securerandom"

class DemoCorpusSeeder
  SOURCE_PATHS = [
    "README.md",
    *Rails.root.glob("docs/adr/*.md").map { |path| path.relative_path_from(Rails.root).to_s }.sort
  ].freeze

  def call
    user = User.find_or_initialize_by(email_address: DemoAccess.email_address)
    user.password = SecureRandom.hex(32) if user.new_record?
    user.save!

    SOURCE_PATHS.each do |relative_path|
      path = Rails.root.join(relative_path)
      next unless path.file?

      document = user.documents.find_or_initialize_by(source_uri: relative_path)
      document.assign_attributes(
        title: title_for(path),
        content_type: "text/markdown",
        raw_text: path.read,
        status: :pending
      )
      document.save!
      DocumentIngestor.new(document).call
    end

    user
  end

  private

  def title_for(path)
    heading = path.each_line.lazy.map(&:strip).find { |line| line.start_with?("# ") }
    heading&.delete_prefix("# ") || path.basename(".md").to_s.humanize
  end
end
