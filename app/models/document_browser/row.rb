# frozen_string_literal: true

# One row in the document browser (M8 locked decision 2). Both pages render
# this shape; each factory reads its model once, so the two families cannot
# drift apart and the component stays a pure renderer.
class DocumentBrowser::Row
  Status = Data.define(:label, :tone)
  Action = Data.define(:label, :icon, :url, :method, :tone)

  STATUS_TONES = {
    "queued" => :neutral, "processing" => :info, "unlinked" => :neutral,
    "suggested" => :warning, "pending_review" => :warning,
    "linked" => :success, "verified" => :success,
    "dismissed" => :neutral, "failed" => :error
  }.freeze

  attr_reader :record, :key, :title, :doc_type_label, :kind, :thumb_url, :icon,
              :statuses, :date, :tags, :merchant, :amount, :file_url, :download_url,
              :viewer_url, :details_url, :actions, :failure_message

  def initialize(record:, key:, title:, doc_type_label:, kind:, thumb_url:, icon:,
                 statuses:, date:, tags:, merchant:, amount:, file_url:, download_url:,
                 viewer_url:, details_url:, actions:, failure_message: nil)
    @record = record
    @key = key
    @title = title
    @doc_type_label = doc_type_label
    @kind = kind
    @thumb_url = thumb_url
    @icon = icon
    @statuses = statuses
    @date = date
    @tags = tags
    @merchant = merchant
    @amount = amount
    @file_url = file_url
    @download_url = download_url
    @viewer_url = viewer_url
    @details_url = details_url
    @actions = actions
    @failure_message = failure_message
  end

  class << self
    def for_document_link(link, viewer_url: nil)
      routes = Rails.application.routes.url_helpers
      draft = link.receipt_imports.max_by(&:created_at)
      ready = link.paperless_document_id.present?

      new(
        record: link,
        key: "document_link_#{link.id}",
        title: link.title.presence || link.original_filename,
        doc_type_label: I18n.t("documents.source.#{link.source}"),
        kind: viewer_kind(link.content_type),
        thumb_url: (routes.file_document_path(link, kind: "thumb") if ready),
        icon: icon_for(link.content_type),
        statuses: [ Status.new(label: I18n.t("documents.status.#{link.status}"), tone: STATUS_TONES.fetch(link.status, :neutral)) ],
        date: draft&.purchase_date || link.created_at.to_date,
        tags: link.paperless_tags,
        merchant: draft&.payee,
        amount: draft&.total_amount,
        file_url: (routes.file_document_path(link, kind: "original") if ready),
        # (repaired 2026-10-11, verifier F11) the proxy forces an inline
        # disposition; `download: true` flips it to an attachment so the
        # row/viewer Download affordance actually downloads.
        download_url: (routes.file_document_path(link, kind: "original", download: true) if ready),
        viewer_url: viewer_url,
        details_url: nil,
        actions: document_actions(link, draft, routes),
        failure_message: link.failure_message
      )
    end

    def viewer_kind(content_type)
      return :image if content_type.to_s.start_with?("image/")
      return :pdf if content_type.to_s == "application/pdf"

      :unsupported
    end

    def icon_for(content_type)
      case viewer_kind(content_type)
      when :image then "image"
      when :pdf then "file-text"
      else "file"
      end
    end

    private
      def document_actions(link, draft, routes)
        actions = []
        if draft
          # (repaired 2026-10-11, verifier F8) the awaiting_ocr draft keeps a
          # VISIBLE affordance with a nil url — the row partial renders it as
          # a disabled button (the moved M7 Task 9 fence's "Reading…"). The
          # old `if enabled` dropped it, leaving the row bare and the label
          # dead. "Review details" and "Add details" carry their import_path
          # link.
          label, url = case draft.understanding_state
          when "awaiting_ocr" then [ I18n.t("imports.receipt_import.reading"), nil ]
          when "understood" then [ I18n.t("imports.receipt_import.review_details"), routes.import_path(draft) ]
          else [ I18n.t("imports.receipt_import.add_details"), routes.import_path(draft) ]
          end
          actions << Action.new(label: label, icon: "clipboard-check", url: url, method: :get, tone: :neutral)
        end
        actions << Action.new(label: I18n.t("document_browser.row.retry"), icon: "refresh-cw", url: routes.retry_document_path(link), method: :post, tone: :neutral) if link.status.in?(%w[failed queued])
        actions << Action.new(label: I18n.t("document_browser.row.remove"), icon: "trash-2", url: routes.document_path(link), method: :delete, tone: :destructive)
        actions
      end
  end
end
