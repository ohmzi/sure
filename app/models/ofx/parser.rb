require "bigdecimal"
require "rexml/document"
require "stringio"

module Ofx
  # Parses OFX/QFX bank and credit-card statements in both dialects:
  #   * OFX 1.x — SGML: an `OFXHEADER:` prologue, then <OFX>…</OFX> with leaf
  #     tags left unclosed (<TRNAMT>-4.99). Regex-extracted.
  #   * OFX 2.x — strict XML: an <?xml?> + <?OFX?> prologue with every tag
  #     closed. Parsed with REXML.
  #
  # Mirrors QifParser's structure (namespace module, self.parse/self.valid?,
  # encoding normalization, private class helpers).
  module Parser
    FALLBACK_ENCODINGS = %w[Windows-1252 Windows-1250].freeze

    # OFX date fields are YYYYMMDD[HHMMSS[.sss]][tz]; only the date matters.
    OFX_DATE_LENGTH = 8

    def self.parse(source)
      content = read_source(source)
      return [] unless valid?(content)

      content = normalize_line_endings(normalize_encoding(content))

      xml?(content) ? parse_xml_transactions(content) : parse_sgml_transactions(content)
    end

    def self.valid?(content)
      return false if content.blank?

      binary = content.b
      binary.include?("<OFX>") &&
        (binary.include?("OFXHEADER") || binary.include?("<?OFX") || binary.include?("<STMTTRN>"))
    end

    # Same strategy as QifParser.normalize_encoding: accept a byte stream that
    # is already valid UTF-8, else transcode from the first code page that
    # defines every byte, else scrub.
    def self.normalize_encoding(content)
      return content if content.nil?

      binary = content.b

      utf8_attempt = binary.dup.force_encoding("UTF-8")
      return utf8_attempt if utf8_attempt.valid_encoding?

      FALLBACK_ENCODINGS.each do |encoding|
        begin
          return binary.encode("UTF-8", encoding)
        rescue Encoding::UndefinedConversionError
          next
        end
      end

      binary.encode("UTF-8", "Windows-1252", invalid: :replace, undef: :replace, replace: "")
    end

    def self.read_source(source)
      return source if source.is_a?(String)
      return source.read if source.respond_to?(:read)

      source.to_s
    end
    private_class_method :read_source

    def self.xml?(content)
      content.match?(/\A\s*<\?xml/i)
    end
    private_class_method :xml?

    def self.parse_xml_transactions(content)
      document = REXML::Document.new(content)
      rows = []

      REXML::XPath.each(document, "//STMTTRN") do |element|
        row = build_row(
          date:    text_of(element, "DTPOSTED"),
          amount:  text_of(element, "TRNAMT"),
          payee:   text_of(element, "NAME"),
          memo:    text_of(element, "MEMO"),
          fitid:   text_of(element, "FITID")
        )
        rows << row if row
      end

      rows
    rescue REXML::ParseException
      # Fall back to the tolerant SGML extractor rather than losing the file.
      parse_sgml_transactions(content)
    end
    private_class_method :parse_xml_transactions

    def self.parse_sgml_transactions(content)
      content.scan(/<STMTTRN>(.*?)<\/STMTTRN>/mi).filter_map do |captures|
        block = captures.first
        build_row(
          date:   field(block, "DTPOSTED"),
          amount: field(block, "TRNAMT"),
          payee:  field(block, "NAME"),
          memo:   field(block, "MEMO"),
          fitid:  field(block, "FITID")
        )
      end
    end
    private_class_method :parse_sgml_transactions

    # SGML leaf tags are unclosed, so a value runs until the next "<" or EOL.
    # The same pattern still reads a closed <TAG>value</TAG> correctly.
    def self.field(block, tag)
      block[/<#{tag}>([^<\r\n]+)/i, 1]&.strip
    end
    private_class_method :field

    def self.text_of(element, tag)
      element.elements[tag]&.text&.strip
    end
    private_class_method :text_of

    def self.build_row(date:, amount:, payee:, memo:, fitid:)
      parsed_date = parse_date(date)
      parsed_amount = parse_amount(amount)
      return nil unless parsed_date && parsed_amount

      Row.new(
        date:   parsed_date,
        amount: parsed_amount,
        payee:  payee.presence,
        memo:   memo.presence,
        fitid:  fitid.presence
      )
    end
    private_class_method :build_row

    def self.parse_date(raw)
      return nil if raw.blank?

      Date.strptime(raw.to_s[0, OFX_DATE_LENGTH], "%Y%m%d")
    rescue Date::Error, ArgumentError
      nil
    end
    private_class_method :parse_date

    def self.parse_amount(raw)
      return nil if raw.blank?

      BigDecimal(raw.to_s.delete(","))
    rescue ArgumentError, TypeError
      nil
    end
    private_class_method :parse_amount

    def self.normalize_line_endings(content)
      content.gsub(/\r\n/, "\n").gsub(/\r/, "\n")
    end
    private_class_method :normalize_line_endings
  end
end
