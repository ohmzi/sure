require "test_helper"

class Merchant::NameNormalizerTest < ActiveSupport::TestCase
  test "maps known variants to one canonical merchant" do
    [
      "AMZN Mktp CA SAMPLE ON",
      "AMZN Mktp CA*SAMPLE SAMPLE ON",
      "AMAZON RETA* 000000 SAMPLE WA",
      "Amazon.ca SAMPLE ON",
      "Amazon.ca*SAMPLE SAMPLE ON",
      "Amazon.com",
      "Amazon.ae",
      "Amazon Channels SAMPLE ON"
    ].each do |name|
      assert_equal "Amazon", Merchant::NameNormalizer.canonical_name(name), name
    end

    assert_equal "Home Depot", Merchant::NameNormalizer.canonical_name("THE HOME DEPOT #0000 SAMPLE ON")
    assert_equal "Home Depot", Merchant::NameNormalizer.canonical_name("HOME DEPOT #0000 SAMPLE ON")
    assert_equal "Dollarama", Merchant::NameNormalizer.canonical_name("DOLLARAMA #0000 SAMPLE ON")
    assert_equal "IKEA", Merchant::NameNormalizer.canonical_name("IKEA SAMPLE ON")
    assert_equal "AliExpress", Merchant::NameNormalizer.canonical_name("aliexpress SAMPLE ON")
  end

  test "leaves an unknown merchant unchanged" do
    assert_equal "SAMPLE CORNER STOP ON", Merchant::NameNormalizer.canonical_name("SAMPLE CORNER STOP ON")
  end
end
