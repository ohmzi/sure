require "test_helper"

class ReceiptMatcher::PayeeSimilarityTest < ActiveSupport::TestCase
  test "identical normalized names score 1.0" do
    assert_equal 1.0, ReceiptMatcher::PayeeSimilarity.call("Starbucks Coffee", "STARBUCKS  coffee!")
  end

  test "a shared first word with a typo scores strictly between 0 and 1" do
    score = ReceiptMatcher::PayeeSimilarity.call("Blue Bottle", "Blue Bottl")

    assert_operator score, :>, 0.5
    assert_operator score, :<, 1.0
  end

  test "unrelated names score below a strong match" do
    assert_operator ReceiptMatcher::PayeeSimilarity.call("Starbucks", "Shell Gas"), :<, 0.4
  end

  test "a blank side scores 0.0" do
    assert_equal 0.0, ReceiptMatcher::PayeeSimilarity.call(nil, "Starbucks")
    assert_equal 0.0, ReceiptMatcher::PayeeSimilarity.call("", "Starbucks")
  end
end
