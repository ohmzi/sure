# frozen_string_literal: true

# The shared document browser (M8 locked decisions 2/14): one rendering path
# for Receipts & Bills and Statements. It renders a uniform
# DocumentBrowser::Row list; per-page differences arrive as parameters.
class DocumentBrowserComponent < ApplicationComponent
  renders_one :upload

  def initialize(family:, title:, url:, rows:, pagy:, filters: {}, source_filter: nil, tag_choices: [])
    @family = family
    @title = title
    @url = url
    @rows = rows
    @pagy = pagy
    @filters = filters
    @source_filter = source_filter
    @tag_choices = tag_choices
  end

  attr_reader :family, :title, :url, :rows, :pagy, :filters, :source_filter, :tag_choices

  def documents? = family == :documents

  # `source` is top-level (the M7-pinned shape), so it is not part of `filters`.
  def active_filters?
    filters.values.any?(&:present?) ||
      (documents? && source_filter.present? && source_filter.sort != DocumentLinksController::DEFAULT_SOURCES.sort)
  end
end
