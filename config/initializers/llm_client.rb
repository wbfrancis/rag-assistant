# Wire the real OpenAI backend in non-test environments, but only if an API key
# is actually configured — otherwise leave the PendingBackend in place so the
# app boots and you get a clear NotConfiguredError on first use rather than a
# silent no-op. Tests assign FakeLlmClient themselves, so we never touch the
# network in CI.
unless Rails.env.test?
  Rails.application.config.after_initialize do
    if LlmClient::OpenaiBackend.api_key.present?
      LlmClient.backend = LlmClient::OpenaiBackend.new
    end
  end
end
