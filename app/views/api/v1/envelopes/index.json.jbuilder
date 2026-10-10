# frozen_string_literal: true

json.envelopes @envelopes do |envelope|
  json.partial! "envelope", envelope: envelope, include_derived_amounts: false
end

json.pagination do
  json.page @pagy.page
  json.per_page @per_page
  json.total_count @pagy.count
  json.total_pages @pagy.pages
end
