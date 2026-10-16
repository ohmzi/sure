require "test_helper"

class Provider::RegistryTest < ActiveSupport::TestCase
  test "providers filters out nil values when provider is not configured" do
    # Ensure no LLM provider is configured
    ClimateControl.modify(
      "OPENAI_ACCESS_TOKEN" => nil,
      "ANTHROPIC_ACCESS_TOKEN" => nil,
      "ANTHROPIC_API_KEY" => nil
    ) do
      Setting.stubs(:openai_access_token).returns(nil)
      Setting.stubs(:anthropic_access_token).returns(nil)

      registry = Provider::Registry.for_concept(:llm)

      # Should return empty array instead of [nil]
      assert_equal [], registry.providers
    end
  end

  test "providers returns configured providers" do
    # Mock a configured OpenAI provider
    mock_provider = mock("openai_provider")
    Provider::Registry.stubs(:openai).returns(mock_provider)

    registry = Provider::Registry.for_concept(:llm)

    assert_equal [ mock_provider ], registry.providers
  end

  test "get_provider raises error when provider not found for concept" do
    registry = Provider::Registry.for_concept(:llm)

    error = assert_raises(Provider::Registry::Error) do
      registry.get_provider(:nonexistent)
    end

    assert_match(/Provider 'nonexistent' not found for concept: llm/, error.message)
  end

  test "get_provider returns nil when provider not configured" do
    # Ensure OpenAI is not configured
    ClimateControl.modify("OPENAI_ACCESS_TOKEN" => nil) do
      Setting.stubs(:openai_access_token).returns(nil)

      registry = Provider::Registry.for_concept(:llm)

      # Should return nil when provider method exists but returns nil
      assert_nil registry.get_provider(:openai)
    end
  end

  test "anthropic provider returns nil when no credentials are configured" do
    ClimateControl.modify(
      "ANTHROPIC_ACCESS_TOKEN" => nil,
      "ANTHROPIC_API_KEY" => nil
    ) do
      Setting.stubs(:anthropic_access_token).returns(nil)

      assert_nil Provider::Registry.get_provider(:anthropic)
    end
  end

  test "anthropic provider initializes from ANTHROPIC_API_KEY env" do
    ClimateControl.modify("ANTHROPIC_API_KEY" => "fake-anthropic-key-for-tests", "ANTHROPIC_ACCESS_TOKEN" => nil) do
      Setting.stubs(:anthropic_access_token).returns(nil)

      provider = Provider::Registry.get_provider(:anthropic)

      assert_instance_of Provider::Anthropic, provider
    end
  end

  test "anthropic provider falls back to Setting when ENV is empty" do
    ClimateControl.modify(
      "ANTHROPIC_ACCESS_TOKEN" => "",
      "ANTHROPIC_API_KEY" => "",
      "ANTHROPIC_BASE_URL" => "",
      "ANTHROPIC_MODEL" => ""
    ) do
      Setting.stubs(:anthropic_access_token).returns("fake-anthropic-key-from-setting")
      Setting.stubs(:anthropic_base_url).returns(nil)
      Setting.stubs(:anthropic_model).returns(nil)

      provider = Provider::Registry.get_provider(:anthropic)

      assert_instance_of Provider::Anthropic, provider
    end
  end

  test "openai provider falls back to Setting when ENV is empty string" do
    # Mock ENV to return empty string (common in Docker/env files)
    # Use stub_env helper which properly stubs ENV access
    ClimateControl.modify(
      "OPENAI_ACCESS_TOKEN" => "",
      "OPENAI_URI_BASE" => "",
      "OPENAI_MODEL" => ""
    ) do
      Setting.stubs(:openai_access_token).returns("test-token-from-setting")
      Setting.stubs(:openai_uri_base).returns(nil)
      Setting.stubs(:openai_model).returns(nil)

      provider = Provider::Registry.get_provider(:openai)

      # Should successfully create provider using Setting value
      assert_not_nil provider
      assert_instance_of Provider::Openai, provider
    end
  end

  test "preferred_llm_provider returns openai by default" do
    openai = mock("openai")
    Provider::Registry.stubs(:openai).returns(openai)
    Provider::Registry.stubs(:anthropic).returns(mock("anthropic"))
    Setting.stubs(:llm_provider).returns("openai")

    assert_same openai, Provider::Registry.preferred_llm_provider
  end

  test "preferred_llm_provider returns anthropic when selected" do
    anthropic = mock("anthropic")
    Provider::Registry.stubs(:openai).returns(mock("openai"))
    Provider::Registry.stubs(:anthropic).returns(anthropic)
    Setting.stubs(:llm_provider).returns("anthropic")

    assert_same anthropic, Provider::Registry.preferred_llm_provider
  end

  test "preferred_llm_provider falls back to the configured provider when the selected one is unconfigured" do
    openai = mock("openai")
    Provider::Registry.stubs(:openai).returns(openai)
    Provider::Registry.stubs(:anthropic).returns(nil)
    Setting.stubs(:llm_provider).returns("anthropic")

    assert_same openai, Provider::Registry.preferred_llm_provider
  end

  test "preferred_llm_provider returns nil when no provider is configured" do
    Provider::Registry.stubs(:openai).returns(nil)
    Provider::Registry.stubs(:anthropic).returns(nil)
    Setting.stubs(:llm_provider).returns("openai")

    assert_nil Provider::Registry.preferred_llm_provider
  end

  # --- Local provider (spec N5) ---

  # F1: the local endpoint is built with its OWN token (the non-secret
  # placeholder by default), never the cloud key — so a stored DeepSeek/OpenAI
  # key is never sent to a LAN or mistyped local URL.
  test "local provider is built from the local settings, never the cloud key" do
    ClimateControl.modify("OPENAI_ACCESS_TOKEN" => nil) do
      Setting.stubs(:llm_provider).returns("local")
      Setting.stubs(:local_llm_model).returns("llama3.2-vision")
      Setting.stubs(:local_llm_base_url).returns("http://host.docker.internal:11434/v1")
      Setting.stubs(:local_llm_token).returns(nil)
      # A cloud key IS configured — it must not be used for the local endpoint.
      Setting.stubs(:openai_access_token).returns("cloud-secret-key")

      Provider::Openai.expects(:new)
        .with("ollama-local", uri_base: "http://host.docker.internal:11434/v1", model: "llama3.2-vision")
        .returns(:local_client)

      assert_equal :local_client, Provider::Registry.get_provider(:openai)
    end
  end

  test "local provider uses a configured local token and the default base url" do
    Setting.stubs(:llm_provider).returns("local")
    Setting.stubs(:local_llm_model).returns("llama3.2-vision")
    Setting.stubs(:local_llm_base_url).returns(nil)
    Setting.stubs(:local_llm_token).returns("my-lan-token")

    Provider::Openai.expects(:new)
      .with("my-lan-token", uri_base: "http://host.docker.internal:11434/v1", model: "llama3.2-vision")
      .returns(:local_client)

    assert_equal :local_client, Provider::Registry.get_provider(:openai)
  end

  test "preferred_llm_provider resolves to the local provider when local is selected" do
    Setting.stubs(:llm_provider).returns("local")
    Provider::Registry.stubs(:openai).returns(:local_client)
    # Even with a working cloud provider, local must win.
    Provider::Registry.stubs(:anthropic).returns(:anthropic_client)

    assert_equal :local_client, Provider::Registry.preferred_llm_provider
  end

  # F5: local with no model resolves to nil — never a cloud fallback — even when
  # a cloud provider is fully configured.
  test "preferred_llm_provider returns nil for local with no model, not a cloud fallback" do
    Setting.stubs(:llm_provider).returns("local")
    Setting.stubs(:local_llm_model).returns(nil)
    Setting.stubs(:openai_access_token).returns("cloud-key")
    Setting.stubs(:anthropic_access_token).returns("cloud-anthropic-key")

    assert_nil Provider::Registry.preferred_llm_provider
  end

  # --- Cloud document readers (DeepSeek, Gemini) ---

  test "deepseek reader is unconfigured without a key" do
    Setting.stubs(:deepseek_api_key).returns(nil)

    assert_nil Provider::Registry.get_provider(:deepseek)
  end

  test "deepseek reader is built on DeepSeek's endpoint with its own key and the default model" do
    Setting.stubs(:deepseek_api_key).returns("ds-key")
    Setting.stubs(:deepseek_model).returns(nil)

    Provider::Openai.expects(:new)
      .with("ds-key", uri_base: "https://api.deepseek.com", model: "deepseek-flash")
      .returns(:deepseek_client)

    assert_equal :deepseek_client, Provider::Registry.get_provider(:deepseek)
  end

  test "gemini reader is built on Google's OpenAI-compatible endpoint with a chosen model" do
    Setting.stubs(:gemini_api_key).returns("g-key")
    Setting.stubs(:gemini_model).returns("gemini-3.1-flash-lite")

    Provider::Openai.expects(:new)
      .with("g-key", uri_base: "https://generativelanguage.googleapis.com/v1beta/openai",
            model: "gemini-3.1-flash-lite")
      .returns(:gemini_client)

    assert_equal :gemini_client, Provider::Registry.get_provider(:gemini)
  end

  test "cloud_document_readers lists the configured cloud readers, DeepSeek first" do
    Provider::Registry.stubs(:deepseek).returns(:deepseek_client)
    Provider::Registry.stubs(:gemini).returns(:gemini_client)

    assert_equal [ :deepseek_client, :gemini_client ], Provider::Registry.cloud_document_readers
  end

  test "cloud_document_readers skips a reader that has no key" do
    Provider::Registry.stubs(:deepseek).returns(nil)
    Provider::Registry.stubs(:gemini).returns(:gemini_client)

    assert_equal [ :gemini_client ], Provider::Registry.cloud_document_readers
  end

  # The cloud readers never borrow the general OpenAI key: a key stored for one
  # service must never be sent to another's endpoint.
  test "the cloud readers never fall back to the OpenAI key" do
    Setting.stubs(:deepseek_api_key).returns(nil)
    Setting.stubs(:gemini_api_key).returns(nil)
    Setting.stubs(:openai_access_token).returns("openai-key")

    assert_nil Provider::Registry.get_provider(:deepseek)
    assert_nil Provider::Registry.get_provider(:gemini)
  end
end
