require "test_helper"

# The order a document's model read is tried in: the household's selected
# provider first, then the cloud readers (spec §2). "Retry with local model"
# and "Retry with online AI" each pick one rung.
class DocumentReaderLadderTest < ActiveSupport::TestCase
  setup do
    Setting.stubs(:llm_provider).returns("local")
    Setting.stubs(:local_llm_model).returns("qwen2.5vl:7b")
    Setting.stubs(:local_llm_base_url).returns("http://host.docker.internal:11434/v1")
    Setting.stubs(:cloud_document_fallback).returns(true)
    Provider::Registry.stubs(:local_document_reader).returns(:local_client)
    Provider::Registry.stubs(:preferred_llm_provider).returns(:local_client)
    Provider::Registry.stubs(:get_provider).with(:deepseek).returns(:deepseek_client)
    Provider::Registry.stubs(:get_provider).with(:gemini).returns(:gemini_client)
    Provider::Registry.stubs(:get_provider).with(:gemini_lite).returns(nil)
  end

  def ladder(mode) = DocumentReaderLadder.for(mode: mode)

  test "auto tries the local model, then DeepSeek, then Gemini" do
    readers = ladder("auto")

    assert_equal %i[local cloud cloud], readers.map(&:kind)
    assert_equal [ :local_client, :deepseek_client, :gemini_client ], readers.map(&:provider)
    assert_equal [ "the local model (qwen2.5vl:7b)", "DeepSeek", "Gemini" ], readers.map(&:label)
  end

  test "only the local reader carries a GPU guard" do
    readers = ladder("auto")

    assert_instance_of LocalLlm::GpuGuard, readers.first.guard
    assert_nil readers.second.guard
  end

  test "auto stops after the selected provider when cloud fallback is off" do
    Setting.stubs(:cloud_document_fallback).returns(false)

    assert_equal %i[local], ladder("auto").map(&:kind)
  end

  test "auto starts with a cloud provider the household selected, unguarded" do
    Setting.stubs(:llm_provider).returns("openai")
    Provider::Registry.stubs(:preferred_llm_provider).returns(:openai_client)

    readers = ladder("auto")
    assert_equal %i[selected cloud cloud], readers.map(&:kind)
    assert_nil readers.first.guard
  end

  test "auto skips a missing cloud key" do
    Provider::Registry.stubs(:get_provider).with(:deepseek).returns(nil)

    assert_equal [ "the local model (qwen2.5vl:7b)", "Gemini" ], ladder("auto").map(&:label)
  end

  test "online uses only the cloud readers, even with automatic fallback off" do
    Setting.stubs(:cloud_document_fallback).returns(false)

    assert_equal %w[DeepSeek Gemini], ladder("online").map(&:label)
  end

  test "local uses only the local model, whichever provider is selected" do
    Setting.stubs(:llm_provider).returns("openai")

    assert_equal [ :local_client ], ladder("local").map(&:provider)
  end

  test "local is empty when no local model is set up" do
    Provider::Registry.stubs(:local_document_reader).returns(nil)

    assert_empty ladder("local")
  end

  # Gap 8: Gemini's default model answered 503 all day; its lighter model was up.
  test "Gemini's lighter model follows when the configured one differs, only as Gemini's fallback" do
    Provider::Registry.stubs(:get_provider).with(:gemini_lite).returns(:gemini_lite_client)

    readers = ladder("auto")
    assert_equal [ "the local model (qwen2.5vl:7b)", "DeepSeek", "Gemini", "Gemini (lite)" ], readers.map(&:label)
    assert_equal "Gemini", readers.last.fallback_for
    assert_nil readers.second.fallback_for
  end
end
