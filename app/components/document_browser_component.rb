# frozen_string_literal: true

# The shared document browser (M8 locked decisions 2/14): one rendering path
# for the Documents page and the Statements vault. It renders a uniform
# DocumentBrowser::Row list; per-page differences arrive as parameters.
#
# Milestone B (design D3) adds `layout:`: the Documents page is a thumbnail
# `:grid` (the default — you recognise a document by its picture), while the
# Statements vault keeps the `:list` of rows it reconciles with. Only the row
# renderer changes; the header, filters, pagination and empty state are shared.
class DocumentBrowserComponent < ApplicationComponent
  LAYOUTS = %i[grid list].freeze

  renders_one :upload
  # The design's "needs you" strip (D5), documents-only. A slot so the vault
  # never grows one, and so the browser stays a pure renderer.
  renders_one :attention

  def initialize(family:, title:, url:, rows:, pagy:, filters: {}, tag_choices: [], layout: :grid)
    @family = family
    @title = title
    @url = url
    @rows = rows
    @pagy = pagy
    @filters = filters
    @tag_choices = tag_choices
    @layout = LAYOUTS.include?(layout.to_sym) ? layout.to_sym : :grid
  end

  attr_reader :family, :title, :url, :rows, :pagy, :filters, :tag_choices, :layout

  def documents? = family == :documents
  def grid? = layout == :grid

  def active_filters?
    filters.values.any?(&:present?)
  end

  # The duplicate review is a review that empties itself: once every group is
  # reduced to one document, the filtered page has no rows and should say so
  # rather than showing the generic "nothing matches" state. Ask whether the
  # duplicate groups themselves are gone, never whether the filtered relation
  # is empty: a type or search filter can also empty the page while groups
  # still exist, and that must not claim the review is clear.
  def duplicate_review_clear?
    filters[:duplicates].present? && Current.family.present? &&
      DocumentLink.duplicate_representative_ids(Current.family).empty?
  end

  # The chips and the badge count (the Documents redesign). Amounts read in the
  # family's own currency.
  def active_filter_chips
    DocumentBrowser::ActiveFilters.new(filters: filters, url: url, family: family,
                                       currency: Current.family&.currency || "USD")
  end
end
