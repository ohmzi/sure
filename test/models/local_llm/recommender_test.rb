require "test_helper"

# The recommender is pure, so these are the cheapest and most load-bearing
# tests in the wave: the whole "recommend a model for the OCR job" ask is a
# predicate — does the model accept images — plus a quality/CPU ranking.
class LocalLlm::RecommenderTest < ActiveSupport::TestCase
  def recommender(*ids)
    LocalLlm::Recommender.new(ids.map { |id| { id: id, label: id } })
  end

  test "recommends qwen2.5vl:3b over the 7b and text models" do
    r = recommender("llama3.1:8b", "qwen2.5vl:7b", "qwen2.5vl:3b")

    assert_equal "qwen2.5vl:3b", r.recommendation[:top_pick]
    assert_equal :recommended, r.recommendation[:tier]
    assert r.recommendation[:reason].present?
  end

  test "prefers a recommended model over a merely good one regardless of order" do
    assert_equal "qwen2.5vl:3b", recommender("qwen2.5vl:7b", "qwen2.5vl:3b").recommendation[:top_pick]
    assert_equal "qwen2.5vl:3b", recommender("qwen2.5vl:3b", "qwen2.5vl:7b").recommendation[:top_pick]
  end

  test "the qwen3-vl thinking default is flagged, only the -instruct tag is recommended" do
    r = recommender("qwen3-vl:4b")

    assert_equal :needs_instruct, r.classify("qwen3-vl:4b")
    assert r.vision_capable?("qwen3-vl:4b")
    assert_includes r.suitability_for("qwen3-vl:4b"), "instruct"
    assert_equal :recommended, r.classify("qwen3-vl:4b-instruct")
  end

  test "text-only ids are not vision capable" do
    r = recommender("llama3.1:8b")

    assert_equal :text_only, r.classify("llama3.1:8b")
    refute r.vision_capable?("llama3.1:8b")
  end

  test "an all-text-only install has no recommendation" do
    assert_nil recommender("llama3.1:8b", "mistral:7b", "deepseek-chat").recommendation
  end

  test "an empty install has no recommendation and does not raise" do
    assert_nil LocalLlm::Recommender.new([]).recommendation
    assert_nil LocalLlm::Recommender.new(nil).recommendation
  end

  test "classifies the whole tier table" do
    r = recommender

    assert_equal :recommended, r.classify("qwen2.5vl:3b")
    assert_equal :recommended, r.classify("qwen2.5vl:3b-instruct")
    assert_equal :recommended, r.classify("qwen3-vl:4b-instruct")
    assert_equal :good, r.classify("qwen2.5vl:7b")
    assert_equal :good, r.classify("qwen2.5vl")
    assert_equal :fair, r.classify("minicpm-v:8b")
    assert_equal :fair, r.classify("gemma3:4b")
    assert_equal :heavy, r.classify("llama3.2-vision:11b")
    assert_equal :light, r.classify("granite3.2-vision:2b")
    assert_equal :light, r.classify("moondream:1.8b")
    assert_equal :vision_unknown, r.classify("llava:13b")
    assert_equal :text_only, r.classify("qwen2.5:7b")
    assert_equal :text_only, r.classify("deepseek-chat")
  end

  test "does not mistake a 13b tag for the recommended 3b" do
    assert_equal :good, recommender.classify("qwen2.5vl:13b")
  end

  test "vision capability spans every non-text tier" do
    r = recommender

    assert r.vision_capable?("qwen2.5vl:3b")
    assert r.vision_capable?("llama3.2-vision:11b")
    assert r.vision_capable?("gemma3:4b")
    assert r.vision_capable?("moondream:1.8b")
    refute r.vision_capable?("qwen2.5:7b")
  end

  test "suitability_for returns a human label, text-only names the limitation" do
    r = recommender

    assert r.suitability_for("qwen2.5vl:3b").present?
    assert_match(/cannot read document images/i, r.suitability_for("llama3.1:8b"))
  end
end
