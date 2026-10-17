require "test_helper"

# DeepSeek and Gemini as first-class AI providers (the owner, 2026-10-17): the
# selected one leads chat, PDF and categorization, and the others stay as
# fallbacks; chosen nowhere, they never claim another provider's models.
class Provider::RegistryLlmChoiceTest < ActiveSupport::TestCase
  setup do
    Setting.deepseek_api_key = "ds-test"
    Setting.gemini_api_key = "gm-test"
  end

  teardown do
    Setting.llm_provider = "openai"
    Setting.deepseek_api_key = nil
    Setting.gemini_api_key = nil
  end

  test "a selected DeepSeek leads the LLM providers and the preferred provider" do
    Setting.llm_provider = "deepseek"

    assert Provider::Registry.preferred_llm_provider.supports_model?(Setting::DEEPSEEK_DEFAULT_MODEL)
    first = Provider::Registry.for_concept(:llm).providers.first
    assert first.supports_model?(Setting::DEEPSEEK_DEFAULT_MODEL)
    assert_equal Setting::DEEPSEEK_DEFAULT_MODEL, Chat.default_model
  end

  test "a selected Gemini is the chat default model" do
    Setting.llm_provider = "gemini"

    assert_equal Setting::GEMINI_DEFAULT_MODEL, Chat.default_model
  end

  test "unselected, DeepSeek and Gemini come after OpenAI and Anthropic" do
    Setting.llm_provider = "openai"

    keys = Provider::Registry.for_concept(:llm).provider_keys
    assert_equal %i[openai anthropic deepseek gemini], keys
  end

  test "the settings accept deepseek and gemini as the provider" do
    assert_includes Setting::LLM_PROVIDERS, "deepseek"
    assert_includes Setting::LLM_PROVIDERS, "gemini"
  end
end
