# Make every generated model/migration use UUID primary keys (architecture
# mandate). Postgres 17 provides gen_random_uuid() in core, so no extra
# extension is needed.
Rails.application.config.generators do |g|
  g.orm :active_record, primary_key_type: :uuid
end
