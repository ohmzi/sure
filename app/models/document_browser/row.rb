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

  # The vault's review badge tones (M8 Task 3): the statement vocabulary is its
  # own enum, so it gets its own map rather than a reuse of STATUS_TONES.
  REVIEW_TONES = {
    "linked" => :success, "rejected" => :warning, "unmatched" => :neutral
  }.freeze

  # Extraction badges render only for the states a reader must see: an
  # extracted (or not-attempted) statement carries no second badge.
  EXTRACTION_TONES = {
    "processing" => :info, "extraction_failed" => :error
  }.freeze

  attr_reader :record, :key, :title, :doc_type_label, :kind, :thumb_url, :icon,
              :statuses, :date, :tags, :merchant, :amount, :file_url, :download_url,
              :viewer_url, :details_url, :actions, :failure_message, :duplicates_count

  def initialize(record:, key:, title:, doc_type_label:, kind:, thumb_url:, icon:,
                 statuses:, date:, tags:, merchant:, amount:, file_url:, download_url:,
                 viewer_url:, details_url:, actions:, failure_message: nil, duplicates_count: 0)
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
    @duplicates_count = duplicates_count
  end

  class << self
    def for_document_link(link, viewer_url: nil, duplicates_count: nil)
      routes = Rails.application.routes.url_helpers
      draft = link.receipt_imports.max_by(&:created_at)
      ready = link.stored_path.present?
      file_kind = viewer_url_kind(link.content_type)

      new(
        record: link,
        key: "document_link_#{link.id}",
        title: link.title.presence || link.original_filename,
        doc_type_label: I18n.t("documents.source.#{link.source}"),
        kind: viewer_kind(link.content_type),
        thumb_url: (routes.file_document_path(link, kind: "thumb") if ready && thumbnail?(link.content_type)),
        icon: icon_for(link.content_type),
        statuses: [ Status.new(label: I18n.t("documents.status.#{link.status}"), tone: STATUS_TONES.fetch(link.status, :neutral)) ],
        # (Ruling M8-C3, 2026-10-11 close-out) the displayed date is the same
        # coerced date the range/sort SQL uses, never the newest draft's date.
        date: link.document_date,
        tags: link.tags,
        merchant: draft&.payee,
        amount: draft&.total_amount,
        # (Ruling M8-C1, 2026-10-11 close-out) the viewer's bytes follow the
        # row's kind, never one hard-coded endpoint — see viewer_url_kind.
        file_url: (routes.file_document_path(link, kind: file_kind) if ready && file_kind),
        # (repaired 2026-10-11, verifier F11) the proxy forces an inline
        # disposition; `download: true` flips it to an attachment so the
        # row/viewer Download affordance actually downloads.
        download_url: (routes.file_document_path(link, kind: "original", download: true) if ready),
        viewer_url: viewer_url,
        # The document's own page (Milestone B Task 4): the stable, dialog-free
        # URL for the same document-left / what-was-understood-right content.
        # Parity with `for_account_statement`; the grid's entry point stays the
        # modal (viewer_url).
        details_url: routes.document_path(link),
        actions: document_actions(link, draft, routes),
        failure_message: link.failure_message,
        # The index batches this for its whole page (DocumentLink.duplicate_counts);
        # a standalone row still computes its own.
        duplicates_count: duplicates_count.nil? ? link.duplicate_documents.count : duplicates_count
      )
    end

    def for_account_statement(statement, viewer_url: nil)
      routes = Rails.application.routes.url_helpers
      link = statement.archived_document_link
      ready = link&.stored_path.present?
      # The vault's own bytes when the archive copy is not there yet (CSV/XLSX/
      # OFX always take this branch); a settled link's bytes come from the
      # proxy so the browser serves them locally.
      content_type = if ready && link.content_type.present?
        link.content_type
      else
        statement.content_type
      end
      attached = statement.original_file.attached?
      file_kind = viewer_url_kind(content_type)

      new(
        record: statement,
        key: "account_statement_#{statement.id}",
        title: statement.filename,
        doc_type_label: I18n.t("account_statements.type.statement"),
        kind: viewer_kind(content_type),
        # No statement thumbnail (vault parity: file-type icons); Task 4's
        # viewer reads file_url and the factory signature stays fixed.
        thumb_url: nil,
        icon: icon_for(content_type),
        statuses: statement_statuses(statement),
        date: statement.period_end_on || statement.created_at.to_date,
        tags: link&.tags || [],
        merchant: statement.institution_name_hint,
        amount: nil, # statements carry no extracted total (M8 locked decision 7)
        file_url: statement_file_url(statement, link, ready, attached, file_kind, routes),
        # Active Storage's helper demands a host unless only_path is pinned; a
        # model-side call has no request context (account.rb's logo-path precedent).
        download_url: (routes.rails_blob_path(statement.original_file, disposition: "attachment", only_path: true) if attached),
        viewer_url: viewer_url,
        details_url: routes.account_statement_path(statement),
        actions: statement_actions(statement, attached, routes)
      )
    end

    def viewer_kind(content_type)
      return :image if content_type.to_s.start_with?("image/")
      return :pdf if content_type.to_s == "application/pdf"

      :unsupported
    end

    # The URL kind the viewer's centre stage must request, decided by the row's
    # kind (Ruling M8-C1, 2026-10-11 close-out): image and PDF rows both read
    # the UPLOADED original, and rows with no in-page preview carry no file URL
    # at all (their bytes ride the download affordance). Every kind serves the
    # document's own stored bytes; the kind only picks the viewer's branch.
    def viewer_url_kind(content_type)
      case viewer_kind(content_type)
      when :image, :pdf then "original"
      end
    end

    # Which documents have a preview to show: an image's own bytes (the browser
    # scales them) and a PDF's rasterized first page (DocumentLink::Thumbnail,
    # which the file endpoint's kind=thumb branch serves). Every other type
    # falls back to its file-type icon.
    def thumbnail?(content_type)
      viewer_kind(content_type).in?(%i[image pdf])
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
        # A statement the read never resolved to an account: the tile says
        # "Which account?" but the tile is purely visual, so the WORKING
        # affordance lives here, in the viewer, and leads to the statement page's
        # picker. The page gates the picker on the viewer's permission, so this
        # action is safe to offer to anyone who can already see the document.
        statement = link.account_statement
        if statement&.needs_account?
          actions << Action.new(label: I18n.t("document_browser.row.assign_account"), icon: "link",
                                url: routes.account_statement_path(statement), method: :get, tone: :neutral)
        end
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

      # The vault's icon-button set as data (vault parity; the ERB twin is
      # account_statements/_row_actions.html.erb — one rendering path, locked
      # decision 2): suggestion link/reject while unmatched, then Details and
      # Download. The link action carries no account_id param — the controller
      # falls back to the stored suggestion, so the button's URL stays bare.
      def statement_actions(statement, attached, routes)
        actions = []
        if statement.unmatched? && statement.suggested_account.present?
          actions << Action.new(label: I18n.t("account_statements.table.link_suggestion"), icon: "link",
                                url: routes.link_account_statement_path(statement), method: :patch, tone: :neutral)
          actions << Action.new(label: I18n.t("account_statements.table.reject"), icon: "x",
                                url: routes.reject_account_statement_path(statement), method: :patch, tone: :neutral)
        end
        actions << Action.new(label: I18n.t("account_statements.table.view"), icon: "eye",
                              url: routes.account_statement_path(statement), method: :get, tone: :neutral)
        if attached
          actions << Action.new(label: I18n.t("account_statements.table.download"), icon: "download",
                                url: routes.rails_blob_path(statement.original_file, disposition: "attachment", only_path: true),
                                method: :get, tone: :neutral)
        end
        actions
      end

      def statement_statuses(statement)
        statuses = [ Status.new(label: I18n.t("account_statements.status.#{statement.review_status}"),
                                tone: REVIEW_TONES.fetch(statement.review_status, :neutral)) ]
        if (tone = EXTRACTION_TONES[statement.extraction_state])
          statuses << Status.new(label: I18n.t("document_browser.row.extraction.#{statement.extraction_state}"), tone: tone)
        end
        statuses
      end

      def statement_file_url(statement, link, ready, attached, file_kind, routes)
        return routes.file_document_path(link, kind: file_kind) if ready && file_kind
        return nil unless attached

        routes.rails_blob_path(statement.original_file, disposition: "inline", only_path: true)
      end
  end
end
