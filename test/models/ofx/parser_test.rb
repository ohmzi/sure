require "test_helper"

class Ofx::ParserTest < ActiveSupport::TestCase
  # Ruling M2-L1: `file_fixture` is an INSTANCE method on ActiveSupport::TestCase
  # (activesupport 8.1.3.1 defines it once, file_fixtures.rb:26 - no class-level
  # reader), so a class-body lambda capturing lexical self cannot call it
  # (NoMethodError on all 7 tests). `file_fixture_path` IS a class_attribute, so
  # the constants read the fixture file directly; the fixtures stay byte-verified
  # and no call site changes. Every other file_fixture call in this plan is in
  # instance context and stays as-is.
  SGML = -> { File.read(File.join(file_fixture_path, "imports/sample.ofx")) }
  XML  = -> { File.read(File.join(file_fixture_path, "imports/sample_v2.ofx")) }
  # (Ruling M2-C3, 2026-10-11 close-out): a crafted document that passes
  # `valid?` but trips REXML's entity-expansion/security guards.
  CRAFTED = -> { File.read(File.join(file_fixture_path, "imports/crafted_entity.ofx")) }

  test "valid? recognizes OFX 1.x SGML" do
    assert Ofx::Parser.valid?(SGML.call)
  end

  test "valid? recognizes OFX 2.x XML" do
    assert Ofx::Parser.valid?(XML.call)
  end

  test "valid? rejects unrelated text" do
    assert_not Ofx::Parser.valid?("plain,text\n1,2\n")
    assert_not Ofx::Parser.valid?("")
    assert_not Ofx::Parser.valid?(nil)
  end

  test "parses OFX 1.x SGML statements into golden rows" do
    rows = Ofx::Parser.parse(SGML.call)

    assert_equal 3, rows.size

    first = rows.first
    assert_equal Date.new(2024, 10, 15), first.date
    assert_equal BigDecimal("-45.99"), first.amount
    assert_equal "GROCERY STORE", first.payee
    assert_equal "Weekly shop", first.memo
    assert_equal "2024101500001", first.fitid

    salary = rows.second
    assert_equal Date.new(2024, 10, 16), salary.date
    assert_equal BigDecimal("1500.00"), salary.amount
    assert_equal "PAYROLL DEPOSIT", salary.payee
    assert_equal "2024101600002", salary.fitid
  end

  test "parses OFX 2.x XML statements into the same golden rows" do
    rows = Ofx::Parser.parse(XML.call)

    assert_equal 3, rows.size
    assert_equal [ Date.new(2024, 10, 15), Date.new(2024, 10, 16), Date.new(2024, 10, 17) ],
                 rows.map(&:date)
    assert_equal [ BigDecimal("-45.99"), BigDecimal("1500.00"), BigDecimal("-12.50") ],
                 rows.map(&:amount)
    # (Ruling M2-C6, 2026-10-11 close-out): the Close-out claims both dialects
    # parse to identical golden rows, so the XML dialect pins payee and memo too.
    assert_equal [ "GROCERY STORE", "PAYROLL DEPOSIT", "COFFEE SHOP" ], rows.map(&:payee)
    assert_equal [ "Weekly shop", "Salary", "Coffee" ], rows.map(&:memo)
    assert_equal [ "2024101500001", "2024101600002", "2024101700003" ], rows.map(&:fitid)
  end

  test "parse accepts an IO as well as a String" do
    io = StringIO.new(SGML.call)
    assert_equal 3, Ofx::Parser.parse(io).size
  end

  test "skips a transaction whose date cannot be parsed" do
    broken = SGML.call.sub("<DTPOSTED>20241015120000[-5:EST]", "<DTPOSTED>not-a-date")

    rows = Ofx::Parser.parse(broken)

    assert_equal 2, rows.size
    assert_not_includes rows.map(&:fitid), "2024101500001"
  end

  test "falls back to the tolerant SGML extractor on malformed XML" do
    broken = XML.call.sub("</OFX>", "<BROKEN></OFX>")

    rows = Ofx::Parser.parse(broken)

    assert_equal 3, rows.size
    assert_equal [ "2024101500001", "2024101600002", "2024101700003" ], rows.map(&:fitid)
  end

  test "a crafted entity-expansion document fails explicitly instead of crashing" do
    # (Ruling M2-C3, 2026-10-11 close-out): REXML's security guard raises bare
    # RuntimeError ("entity expansion has grown too large"), which the
    # ParseException rescue does not cover. The parse must surface it as the
    # explicit ParseError - the upload controller's failed state - and never
    # fall back to the SGML extractor, which would silently emit the rows the
    # XML parser refused.
    crafted = CRAFTED.call

    assert Ofx::Parser.valid?(crafted), "the crafted document still looks like OFX"
    assert_raises(Ofx::Parser::ParseError) { Ofx::Parser.parse(crafted) }
  end

  test "normalize_encoding transcodes Windows-1252 bytes to valid UTF-8" do
    bytes = (+"<NAME>Caf\xE9 Corner</NAME>").b.force_encoding("ASCII-8BIT")

    normalized = Ofx::Parser.normalize_encoding(bytes)

    assert normalized.valid_encoding?
    assert_includes normalized, "Café Corner"
  end
end
