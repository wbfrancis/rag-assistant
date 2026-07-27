namespace :demo do
  desc "Create or refresh the curated portfolio demo user and document corpus"
  task seed: :environment do
    user = DemoCorpusSeeder.new.call
    puts "Demo corpus ready: #{user.documents.count} documents, #{user.chunks.count} chunks"
  end
end
