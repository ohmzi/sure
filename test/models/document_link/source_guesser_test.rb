require "test_helper"

class DocumentLink::SourceGuesserTest < ActiveSupport::TestCase
  test "a bank-statement filename is guessed as a statement" do
    assert_equal :statement, DocumentLink::SourceGuesser.guess(filename: "March-bank-statement.pdf", content_type: "application/pdf")
  end

  test "a plain receipt filename is guessed as a receipt" do
    assert_equal :receipt, DocumentLink::SourceGuesser.guess(filename: "IMG_2041.pdf", content_type: "application/pdf")
  end

  test "an image is always a receipt" do
    assert_equal :receipt, DocumentLink::SourceGuesser.guess(filename: "statement.png", content_type: "image/png")
  end
end
