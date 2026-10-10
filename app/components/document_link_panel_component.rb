# frozen_string_literal: true

class DocumentLinkPanelComponent < ApplicationComponent
  CANDIDATE_LIMIT = 5

  def initialize(entry:)
    @entry = entry
  end

  attr_reader :entry

  def documents = @documents ||= DocumentLink.for_entry(entry).ordered

  # Recent unlinked documents in the same family, offered for one-tap linking
  # (the matcher that ranks them is M3; M1 shows the most recent).
  def candidates
    @candidates ||= DocumentLink.where(family_id: entry.account.family_id, status: "unlinked")
                                .ordered.limit(CANDIDATE_LIMIT)
  end
end
