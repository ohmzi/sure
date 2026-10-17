# frozen_string_literal: true

require "open3"
require "cgi"

# Where on its page a statement line sits (the owner, 2026-10-17): opened from
# a transaction, the viewer shows the page that line is on with the line marked.
#
# The PDF's own text layer says where each word is (`pdftotext -bbox`). The line
# is the amount, printed once, with the most of its description's words around
# it; a word that appears all over the page (a "Transfer" on every row) counts
# for less than one that appears once (a reference number). Scanned pages have
# no text layer, and anything that goes wrong is nil: the viewer then shows the
# page without a mark, or the first page.
class DocumentLink::LineLocator
  # A spot on a page, as percentages of the page so it lays over its picture at
  # any size.
  Mark = Data.define(:page, :top, :height)
  Word = Data.define(:text, :top, :bottom)

  # A description wraps onto the line above or below its amount, never further.
  REACH = 2.2

  def initialize(link)
    @link = link
  end

  # The line printing `amount` (either sign) and described by `name`, on `page`
  # when the read recorded it. nil when it is not found.
  def locate(name:, amount:, page: nil)
    targets = amount_spellings(amount)
    return if targets.empty?

    tokens = name.to_s.split.map { |token| normalize(token) }.select { |token| token.length >= 3 }.uniq

    pages.each_with_index.filter_map do |(height, words), index|
      number = index + 1
      next if page && page.to_i != number

      best_line(words, height, targets, tokens, number)
    end.max_by(&:first)&.last
  end

  private
    def best_line(words, height, targets, tokens, number)
      rarity = words.map { |word| normalize(word.text) }.tally

      words.select { |word| targets.include?(money(word.text)) }.filter_map do |amount_word|
        line = amount_word.bottom - amount_word.top
        centre = (amount_word.top + amount_word.bottom) / 2
        near = words.select { |word| ((word.top + word.bottom) / 2 - centre).abs <= line * REACH }
        described = near.select { |word| tokens.include?(normalize(word.text)) }
        score = described.uniq { |word| normalize(word.text) }.sum { |word| 1.0 / rarity[normalize(word.text)] }
        next if score.zero? && tokens.any?

        # The mark covers the amount's line and the wrapped words only this line
        # has; "Customer Transfer" on the next row is near but not this line.
        spans = described.select { |word| rarity[normalize(word.text)] <= 2 } + [ amount_word ]
        top = spans.map(&:top).min - 1
        bottom = spans.map(&:bottom).max + 1
        [ score, Mark.new(page: number, top: (top / height * 100).round(2), height: ((bottom - top) / height * 100).round(2)) ]
      end.max_by(&:first)
    end

    # [page height, words] per page, from the PDF's text layer.
    def pages
      @pages ||= begin
        source = DocumentLink::Staging.resolve!(@link.stored_path) if DocumentLink::Thumbnail.pdf?(@link) && @link.stored_path.present?
        source&.file? ? parse(text_layer(source)) : []
      rescue ArgumentError, Errno::ENOENT
        []
      end
    end

    def text_layer(source)
      output, status = Open3.capture2("pdftotext", "-bbox", "-l", DocumentLink::PageImage::MAX_PAGES.to_s, source.to_s, "-")
      status.success? ? output : ""
    end

    def parse(html)
      html.split("<page ").drop(1).map do |page|
        height = page[/height="([\d.]+)"/, 1].to_f
        words = page.scan(/<word xMin="[\d.]+" yMin="([\d.]+)" xMax="[\d.]+" yMax="([\d.]+)">([^<]*)<\/word>/).map do |top, bottom, text|
          Word.new(text: CGI.unescapeHTML(text), top: top.to_f, bottom: bottom.to_f)
        end
        [ height.positive? ? height : 1, words ]
      end
    end

    def amount_spellings(amount)
      value = BigDecimal(amount.to_s, exception: false)&.abs
      value ? [ format("%.2f", value) ] : []
    end

    # A printed amount as plain digits: "$1,500.00", "(1,500.00)", "1,500.00-"
    # and "1,500.00CR" all read 1500.00.
    def money(text)
      digits = text.gsub(/[^\d.]/, "")
      digits.match?(/\A\d+\.\d{2}\z/) ? digits : nil
    end

    def normalize(text) = text.downcase.gsub(/[^a-z0-9]/, "")
end
