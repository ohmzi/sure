# frozen_string_literal: true

# One row per read of a document: which provider, model and OCR engine read it,
# what the OCR saw, what the model returned, what the deterministic validators
# made of it, and whether it worked. This is the per-document "what I
# understood" record and the anchor every extracted Import::Row points at, so a
# row is traceable to its source document AND to the exact model that read it.
class DocumentExtraction < ApplicationRecord
  STATUSES = %w[pending succeeded failed].freeze

  belongs_to :family
  belongs_to :document_link
  has_many :imports, dependent: :nullify

  validates :status, inclusion: { in: STATUSES }

  # The single write path. Follows the repo's guarded-write idiom: one method,
  # never a bare create! scattered across jobs.
  def self.record!(document_link:, **attrs)
    create!(family: document_link.family, document_link: document_link, **attrs)
  end
end
