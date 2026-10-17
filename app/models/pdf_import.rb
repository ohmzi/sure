class PdfImport < Import
  has_one_attached :pdf_file, dependent: :purge_later

  validates :document_type, inclusion: { in: DOCUMENT_TYPES }, allow_nil: true
  validate :account_statement_matches_import

  class << self
    # PdfImport's importing status doubles as a processing claim: the AI
    # extraction claim from process_with_ai_later (no rows yet) or a regular
    # publish (rows being written). A lost job leaves the claim held forever —
    # ProcessPdfJob's own reclaim only runs when the job is redelivered.
    # Which claim died is observable from the data: no rows attached → the AI
    # claim, reclaim to pending so the user can re-trigger; rows attached →
    # the publish died after import!'s commit, so finalize as complete
    # (pending would let the user publish the same extracted rows again —
    # PdfImport#import! always builds new transactions). Stuck reverts go to
    # revert_failed like every other import, keeping the retry path exposed.
    def clean
      where(status: [ :importing, :reverting ])
        .where("updated_at < ?", Import::STUCK_AFTER.ago)
        .includes(:family)
        .find_each do |pdf_import|
          reap_stuck!(pdf_import)
        rescue => e
          # One bad record must not abort the sweep for the rest.
          Rails.logger.error("PdfImport.clean failed for #{pdf_import.id}: #{e.class}: #{e.message}")
          Sentry.capture_exception(e) { |scope| scope.set_tags(record_type: name, record_id: pdf_import.id) } if defined?(Sentry)
        end
    end

    def reap_stuck!(pdf_import)
      needs_sync = false
      # Read before the lock — see Import.reap_stuck!.
      family = pdf_import.family

      pdf_import.with_lock do
        next unless pdf_import.reapable_since?(Import::STUCK_AFTER.ago)

        previous_status = pdf_import.status
        if previous_status == "reverting"
          pdf_import.update!(status: :revert_failed, error: Import.interrupted_error_message)
        elsif pdf_import.data_committed?
          pdf_import.update!(status: :complete, error: nil)
          needs_sync = true
        else
          pdf_import.update!(status: :pending)
        end

        DebugLogEntry.capture(
          category: "background_jobs",
          level: "warn",
          message: "Reclaimed PdfImport stuck in #{previous_status} for over #{Import::STUCK_AFTER.inspect} (→ #{pdf_import.status})",
          source: name,
          family: family,
          metadata: { record_type: name, record_id: pdf_import.id, previous_status: previous_status, new_status: pdf_import.status }
        )
      end

      # Outside the row lock — see Import.reap_stuck!.
      family.sync_later if needs_sync
    end

    def create_from_upload!(family:, file:, user:)
      statement = AccountStatement.create_from_prepared_upload!(
        family: family,
        account: nil,
        prepared_upload: AccountStatement.prepare_upload!(file)
      )

      create_from_statement!(statement: statement)
    rescue AccountStatement::DuplicateUploadError => e
      raise unless e.statement.manageable_by?(user)

      create_from_statement!(statement: e.statement)
    end

    def create_from_statement!(statement:)
      reusable_import = statement.latest_reusable_pdf_import
      return reusable_import if reusable_import &&
                                reusable_import.account_id == statement.account_id &&
                                reusable_import.date_format == statement.family.date_format

      # The document anchor (spec N13). A statement's own rows are born off this
      # import, and `EntryProvenance#document_backed?` reads the creating
      # document off `import.document_link` -- so without this link every row a
      # statement produced reads "from a bank export" with no chip back to the
      # document the user uploaded, and `DocumentLink#derived_entries` (the N9
      # delete guard) cannot see them either. Point the import at the statement's
      # own archived link. It is nil for a legacy upload whose archive copy is
      # staged after this call (the vault's own upload path), and present on the
      # native read's route, where the statement is minted from the uploaded
      # document and its link already exists.
      create!(family: statement.family, account: statement.account, account_statement: statement,
              document_link: statement.archived_document_link,
              date_format: statement.family.date_format, status: :pending)
    end

    # The native read's entry point (Task 9). create_from_statement! already
    # reuses a matching import, so a re-run against the SAME statement row is
    # idempotent; this adds the direct lookup by vault row, so a statement whose
    # import would not be reusable (the account or the family's date format moved
    # since) is still adopted rather than duplicated. A retry, a reaper
    # re-enqueue or a reprocess must never mint a second import, and therefore a
    # second set of rows, against one statement.
    def find_or_create_from_statement!(statement:)
      where(account_statement: statement).first || create_from_statement!(statement: statement)
    end
  end

  # A PdfImport's importing status is a processing claim (AI extraction or
  # publish). Release a lost claim back to pending so the user can re-trigger
  # processing, mirroring ProcessPdfJob's own reclaim; lost reverts keep the
  # base revert_failed behavior.
  # Reverting a statement is the owner's decision: record it on the statement's
  # document, so a later re-read never posts it again (review C2 — the same
  # durable mark a reverted receipt auto-post leaves).
  def revert
    super
    return if revert_failed?

    (document_link || account_statement&.archived_document_link)&.mark_auto_post_undone!
  end

  def force_fail!(error_message = Import.lost_error_message)
    return super if reverting?

    with_lock do
      return false unless presumed_lost?

      update!(status: :pending)
    end

    true
  end

  def import!
    raise "Account required for PDF import" unless account.present?

    # (Ruling M2-C10, 2026-10-11: the M7-L8 atomic-guard pattern, deferred by
    # M7's close-out review and closed here) The committed check and the entry
    # write share the import's row lock, so two CONCURRENT publishes of one
    # statement serialize: the loser blocks on the lock, then sees the entries
    # the winner committed and returns before the adapter is ever touched.
    # Without the lock, both submits passed Import#publish's already-published
    # check - a bare check-then-act on the status - and both ran this writer,
    # double-posting the statement (the class Ruling M7-L8 closed for
    # ReceiptImport).
    with_lock do
      if data_committed?
        Rails.logger.info("PdfImport #{id}: publish replayed; the statement's entries already exist - nothing written")
        return
      end

      transaction do
        mappings.each(&:create_mappable!)

        # Rows were already filtered against existing records when they were
        # generated, but a provider sync can land in between, so check again here
        # the way TransactionImport#import! does.
        adapter = Account::ProviderImportAdapter.new(account)
        # Entries this statement already consumed during row generation are spoken
        # for. Without excluding them, a statement carrying two same-amount
        # transactions where the account held only one would re-match the surviving
        # row against that same entry and silently drop a genuinely new
        # transaction. Newly synced entries are still caught, because only the
        # already-reconciled ones are excluded.
        claimed = reconciled_entries.pluck(:id)
        reconciled_now = []
        reconciled_at = Time.current

        new_transactions = rows.filter_map do |row|
          if (existing = already_recorded_entry(adapter, row, claimed))
            claimed << existing.id
            reconciled_now << existing
            next
          end

          Transaction.new(
            category: mappings.categories.mappable_for(row.category),
            entry: Entry.new(
              account: account,
              date: row.date_iso,
              amount: row.signed_amount,
              name: row.name,
              currency: row.currency,
              notes: row.notes,
              import: self,
              import_locked: true,
              # Born reconciled: the statement being imported is the evidence.
              # Set by id rather than association so activerecord-import writes the
              # column directly on the recursive insert.
              reconciled_at: reconciled_at,
              reconciled_by_statement_id: account_statement&.id
            )
          )
        end

        Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
        reconcile_entries!(reconciled_now, at: reconciled_at)
      end
    end

    # The statement's printed opening balance is the account's starting point
    # when this is its earliest statement (the "account update" half of a read).
    StatementBalanceAnchor.call(account_statement) if account_statement
  end

  # Re-targeting is destructive: it releases the statement's evidence on the
  # account being left and rebuilds the rows from scratch. Returns false rather
  # than doing any of that when the import is no longer re-targetable, so a
  # back-button or replayed PATCH cannot unwind a published import.
  def assign_account!(account)
    with_lock do
      # A posted statement whose record was unlinked can always go back to the
      # account its rows already live in — that moves no money. Moving it to any
      # other account stays refused below.
      if !reassignable? && account_id == account.id && (statement = account_statement)
        statement.lock!
        statement.link_to_account!(account) if statement.account_id != account.id
        return true
      end
      return false unless reassignable?

      previous_account_id = account_id
      update!(account: account)

      if (statement = account_statement)
        statement.lock!
        statement.link_to_account!(account) if statement.account_id != account.id
      end

      next true if previous_account_id == account.id

      # Matching is per-account, so anything reconciled against the old account
      # is no longer evidence-backed, and the rows have to be judged again.
      release_reconciliations!(previous_account_id)
      if has_extracted_transactions?
        generate_rows_from_extracted_data
        sync_mappings
        refresh_status_after_regeneration!
      end

      true
    end
  end

  # A published import's entries already live in the account it was published
  # to, and a running job owns the record while it is importing or reverting.
  # An import that reconciled every line is still re-targetable: it is complete
  # but committed nothing of its own, and the user may well have picked the
  # wrong account.
  def reassignable?
    !data_committed? && !importing? && !reverting?
  end

  def pdf_uploaded?
    statement_backed? || pdf_file.attached?
  end

  # The read behind these rows proved them against the statement's own printed
  # totals — the bar for posting them on a person's account pick.
  def reconciled_read?
    document_extraction&.validations&.dig("statement_totals_reconcile") == true
  end

  def ai_processed?
    ai_summary.present?
  end

  def process_with_ai_later
    return false unless with_lock { pending? && !ai_processed? && rows_count.zero? && pdf_uploaded? && update!(status: :importing) }

    begin
      ProcessPdfJob.perform_later(self)
      true
    rescue StandardError => e
      Rails.logger.error("Failed to enqueue PDF processing for import #{id}: #{e.class.name} - #{e.message}")
      reload.with_lock { update!(status: :pending) }
      false
    end
  end

  def process_with_ai
    # Honors Setting.llm_provider (issue #2113) — Provider::Anthropic implements
    # process_pdf (PR #1985).
    provider = Provider::Registry.preferred_llm_provider
    raise Provider::Error, I18n.t("imports.pdf_import.errors.provider_not_configured") unless provider
    raise Provider::Error, I18n.t("imports.pdf_import.errors.provider_no_pdf_support") unless provider.supports_pdf_processing?

    response = provider.process_pdf(
      pdf_content: pdf_file_content,
      family: family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown PDF processing error"
      raise Provider::Error, error_message
    end

    result = response.data
    update!(
      ai_summary: result.summary,
      document_type: result.document_type
    )

    result
  end

  def extract_transactions
    return unless statement_with_transactions?

    # Honors Setting.llm_provider (issue #2113) — Provider::Anthropic implements
    # extract_bank_statement (PR #1985).
    provider = Provider::Registry.preferred_llm_provider
    raise Provider::Error, I18n.t("imports.pdf_import.errors.provider_not_configured") unless provider

    response = provider.extract_bank_statement(
      pdf_content: pdf_file_content,
      family: family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown extraction error"
      raise Provider::Error, error_message
    end

    # BankStatementExtractor returns symbol keys, but every reader here (and in
    # generate_rows_from_extracted_data) digs with strings. jsonb keeps the hash
    # exactly as assigned until the record is reloaded, so without this the
    # in-memory read comes back empty and the import produces no rows at all.
    data = response.data.deep_stringify_keys
    update!(extracted_data: data)
    data
  end

  def bank_statement?
    document_type == "bank_statement"
  end

  def statement_with_transactions?
    document_type.in?(%w[bank_statement credit_card_statement])
  end

  def has_extracted_transactions?
    extracted_data.present? && extracted_data["transactions"].present?
  end

  def extracted_transactions
    extracted_data&.dig("transactions") || []
  end

  def generate_rows_from_extracted_data
    transaction do
      # insert_all! below bypasses ActiveRecord, so the `rows` association is
      # never populated with what it wrote. Reload before destroying, or a second
      # call on the same in-memory record (assign_account! regenerating after
      # ProcessPdfJob already generated) clears a stale empty collection, deletes
      # nothing, and collides on (import_id, source_row_number).
      rows.reload.destroy_all

      unless has_extracted_transactions?
        update_column(:rows_count, 0)
        return
      end

      currency = account&.currency || family.currency
      transactions = extracted_transactions
      fill_missing_dates!(transactions)
      candidates = transactions.map.with_index(1) do |txn, index|
        Import::Row.new(
          import: self,
          source_row_number: index,
          date: format_date_for_import(txn["date"]),
          amount: normalize_amount(txn["amount"]),
          name: txn["name"].to_s,
          category: txn["category"].to_s,
          notes: txn["notes"].to_s,
          # The native read stamps a transaction's page when its batch covered a
          # single page (spec §8.3); nil for every other producer, harmlessly.
          source_page: txn["source_page"],
          currency: currency
        )
      end

      unmatched, matched_entries = partition_already_recorded(candidates)

      reconcile_entries!(matched_entries)

      mapped_rows = unmatched.map.with_index(1) do |row, index|
        {
          import_id: id,
          source_row_number: index,
          date: row.date,
          amount: row.amount,
          name: row.name,
          category: row.category,
          notes: row.notes,
          source_page: row.source_page,
          currency: row.currency
        }
      end

      Import::Row.insert_all!(mapped_rows) if mapped_rows.any?
      # Drop the now-stale association cache so later reads (sync_mappings, the
      # view) see what was actually written.
      rows.reset
      update_column(:rows_count, mapped_rows.size)
    end
  end

  # Transactions this statement reconciled against records that already existed.
  # Derived from the statement link rather than stored, so it cannot go stale.
  def reconciled_entries
    return Entry.none if account_statement.blank?

    Entry.reconciled_by(account_statement)
  end

  # The half of reconciled_entries this import did not create -- transactions the
  # account already held when the statement arrived. Everything this import
  # creates is born reconciled too, so the two have to be told apart before
  # either count means anything.
  def already_recorded_entries
    reconciled_entries.where.not(id: entries.select(:id))
  end

  # The next three are memoized because the summary dialog and the review screen
  # each read them more than once, and every read is its own COUNT -- rendering
  # the dialog issued roughly fifteen queries for a static summary. They report
  # a finished outcome for display, so a value cached for the life of the
  # request is what callers want; anything re-judging the import recomputes from
  # the entries directly. (`||=` is safe here: 0 is truthy in Ruby.)
  def already_recorded_count
    @already_recorded_count ||= already_recorded_entries.count
  end

  def imported_count
    @imported_count ||= entries.count
  end

  # Rows still on offer. import! creates an entry per row and leaves the rows in
  # place as the record of what was published, so past that point rows_count is
  # a history, not a queue. Memoized mostly for data_committed?, which is two
  # more EXISTS queries every time it is asked.
  def awaiting_review_count
    @awaiting_review_count ||= data_committed? ? 0 : rows_count
  end

  # No query: extracted_data is already in memory.
  def extracted_count
    extracted_transactions.size
  end

  # Whether the statement described transactions the account already had. The
  # difference between "nothing to import" and "nothing was found".
  def reconciled_anything?
    already_recorded_count.positive?
  end

  def send_next_steps_email(user)
    PdfImportMailer.with(
      user: user,
      pdf_import: self
    ).next_steps.deliver_later
  end

  def uploaded?
    pdf_uploaded?
  end

  def configured?
    ai_processed? && rows_count > 0
  end

  def cleaned?
    configured? && rows.all?(&:valid?)
  end

  def publishable?
    account.present? && statement_with_transactions? && cleaned? && mappings.all?(&:valid?) && !flagged_duplicate?
  end

  # A statement flagged as a duplicate month is never imported — by auto-post
  # or by hand — until the owner deletes the copy.
  def flagged_duplicate?
    document_link&.hold_reason&.code == "statement_duplicate"
  end

  def cleaned_from_validation_stats?(invalid_rows_count:)
    account.present? && statement_with_transactions? && super
  end

  def publishable_from_validation_stats?(invalid_rows_count:)
    account.present? && statement_with_transactions? && super
  end

  def column_keys
    %i[date amount name category notes]
  end

  def requires_csv_workflow?
    false
  end

  def pdf_file_content
    return @pdf_file_content if defined?(@pdf_file_content)
    return @pdf_file_content = account_statement.original_file.download if statement_backed?

    @pdf_file_content = pdf_file.download if pdf_file.attached?
  end

  def pdf_filename
    return account_statement.filename if statement_backed?

    pdf_file.filename.to_s if pdf_file.attached?
  end

  def statement_backed?
    account_statement&.original_file&.attached?
  end

  def required_column_keys
    %i[date amount]
  end

  def mapping_steps
    base = []
    # Only include CategoryMapping if rows have non-empty categories
    base << Import::CategoryMapping if rows.where.not(category: [ nil, "" ]).exists?
    # Note: PDF imports use direct account selection in the UI, not AccountMapping
    # AccountMapping is designed for CSV imports where rows have different account values
    base
  end

  private

    # A statement's posting date routinely differs by a day or two from the date
    # a provider recorded for the same transaction, so matching allows a small
    # window rather than demanding an exact date.
    RECONCILIATION_DATE_WINDOW = 3

    # Splits candidate rows into those that are genuinely new and the existing
    # entries the rest already correspond to. Matching is per-account, so with no
    # account assigned yet every row is treated as new and judged again once the
    # user picks one (see assign_account!).
    def partition_already_recorded(candidates)
      return [ candidates, [] ] if account.blank?

      adapter = Account::ProviderImportAdapter.new(account)
      claimed = []
      unmatched = []
      matched = []

      candidates.each do |row|
        if (existing = already_recorded_entry(adapter, row, claimed))
          claimed << existing.id
          matched << existing
        else
          unmatched << row
        end
      end

      [ unmatched, matched ]
    end

    # Name is deliberately not part of the match: statement descriptions and
    # provider names for the same transaction rarely agree, and the adapter makes
    # the same choice for provider sync.
    def already_recorded_entry(adapter, row, claimed)
      adapter.find_duplicate_transaction(
        date: row.date_iso,
        amount: row.signed_amount,
        currency: row.currency,
        exclude_entry_ids: claimed,
        date_window: RECONCILIATION_DATE_WINDOW,
        include_provider_entries: true
      )
    rescue ArgumentError, TypeError => e # Date::Error subclasses ArgumentError
      # A row whose date or amount will not parse cannot be judged. Offer it for
      # import rather than dropping it silently -- the review step surfaces it.
      DebugLogEntry.capture(
        category: "import",
        level: "warn",
        message: "PdfImport: could not evaluate statement row for reconciliation (#{e.class})",
        source: "pdf_import",
        family: family,
        account: account,
        metadata: {
          import_id: id,
          account_statement_id: account_statement_id,
          source_row_number: row.source_row_number,
          raw_date: row.date,
          raw_amount: row.amount,
          error_class: e.class.name
        }
      )
      nil
    end

    def reconcile_entries!(entries, at: Time.current)
      return if entries.blank?

      Entry.where(id: entries.map(&:id)).update_all(
        reconciled_at: at,
        reconciled_by_statement_id: account_statement&.id,
        updated_at: at
      )

      statement_link = account_statement&.archived_document_link
      entries.each { |entry| claim!(entry, statement_link) }
    end

    # A statement line matching an entry that already exists -- an auto-posted
    # receipt, a synced row, a hand-entered one -- CLAIMS it (spec N10): one
    # transaction, two sources. Identity cannot see this (the receipt says
    # `document:<link id>`, the statement says `stmt:<sha>:<row>` or, for a PDF,
    # nothing at all), which is why the match is reconcile_entries!'s evidence
    # match and never an id comparison. Attaching the statement's own link is
    # what makes the corroboration durable: EntryProvenance#documents and the
    # row's provenance chips both read `entry.document_links`.
    #
    # Never claims an entry this statement created. `find_duplicate_transaction`
    # does not exclude them, so a REGENERATION (assign_account!, revert, a
    # reprocess) re-judges the statement's own born entries as matched rows;
    # attaching the statement's link to one would make
    # EntryProvenance#corroborated? read true for a document corroborating itself.
    # Two shapes count: an entry THIS import created, and one a SIBLING import
    # for the same vault row created (a family date-format change mints a second
    # import for one statement -- see create_from_statement!).
    #
    # The write goes through DocumentLink#link_to_entry! (the model's single
    # writer for status + entry_id), not `entry.document_links <<`: the
    # association is read-only by contract, and a raw append would leave a row
    # carrying entry_id while still labelled `unlinked`.
    def claim!(entry, statement_link)
      if statement_link.nil?
        # The other skip below (a refused transition) logs too, so an operator
        # can tell "this statement has no archived document link" apart from
        # "the archive failed" -- both otherwise look like a silent no-op.
        Rails.logger.info(
          "PdfImport #{id}: matched entry #{entry.id}, but the statement has no archived " \
          "document link to corroborate with (nothing recorded)"
        )
        return
      end

      return if entry.import_id == id
      return if entry.import_id.present? &&
                PdfImport.where(id: entry.import_id, account_statement_id: account_statement&.id).exists?
      return if entry.document_links.exists?(id: statement_link.id)

      unless statement_link.link_to_entry!(entry)
        Rails.logger.info(
          "PdfImport #{id}: matched entry #{entry.id}, but statement link #{statement_link.id} " \
          "would not link from status #{statement_link.status.inspect}"
        )
      end
    end

    # Regeneration can empty the row set (everything now matches) or refill it
    # (the new account matches nothing). Status has to follow, using the same
    # rule ProcessPdfJob applies after initial processing -- otherwise a
    # fully-matched import sits at pending with no rows, which renders as the
    # processing screen forever and cannot be restarted.
    def refresh_status_after_regeneration!
      return if data_committed?
      return unless pending? || complete?

      target = statement_with_transactions? && rows_count > 0 ? "pending" : "complete"
      update!(status: target) unless status.to_s == target
    end

    # Scoped to the account being moved away from. A statement is evidence for
    # exactly one account at a time, but it can back more than one import, so an
    # unscoped release would clear reconciliations another account still relies
    # on. Nothing is reconciled while no account is assigned, so a blank scope
    # has nothing to release.
    #
    # The claim! corroboration is released with the mark it was recorded
    # alongside: leaving the statement's link on the entry would keep the entry
    # showing the statement as a source while reconciled_by_statement_id is nil
    # -- two provenance signals disagreeing about one entry (spec §8.6's
    # "silently lies"). Only THIS statement's link is detached: the entry's
    # other documents (a receipt's own link) are not this statement's to unlink.
    def release_reconciliations!(account_scope_id)
      return if account_statement.blank? || account_scope_id.blank?

      # The ids are read before the UPDATE, or the relation would come back
      # empty and there would be nothing left to detach.
      released_ids = Entry.reconciled_by(account_statement).where(account_id: account_scope_id).pluck(:id)
      return if released_ids.empty?

      Entry.where(id: released_ids).update_all(
        reconciled_at: nil,
        reconciled_by_statement_id: nil,
        updated_at: Time.current
      )

      statement_link = account_statement.archived_document_link
      return if statement_link.blank?

      DocumentLink.where(id: statement_link.id, entry_id: released_ids).find_each(&:unlink!)
    end

    # Reverting a statement import unwinds its evidence as well as its rows. The
    # entries it created are already destroyed by the time this runs; the ones it
    # only matched keep marks this statement no longer backs. Releasing and then
    # regenerating re-judges every statement line against what the account
    # actually holds now, so the review screen offers exactly what is missing.
    def revert_derived_state!
      release_reconciliations!(account_id)
      return unless has_extracted_transactions?

      generate_rows_from_extracted_data
      # A line that matched at publish time carried no row and so no mapping.
      # If it no longer matches it is a row again, and needs one.
      sync_mappings
    end

    # A statement whose every line still matches something -- a provider-synced
    # account, say -- reverts to zero rows. Returning that to pending renders the
    # processing screen with no way out, so an import with nothing left to offer
    # finishes as complete, the same way refresh_status_after_regeneration! ends
    # a fully reconciled import.
    def status_after_revert
      statement_with_transactions? && rows_count > 0 ? :pending : :complete
    end

    # A statement reader may return a day-first date ("31-03-2026") or a
    # thousands separator in an amount ("3,501.79"). Normalize both before the
    # row validations see them.
    # A statement prints the date once per group, so a row at a page break can
    # arrive with no date. Prefer the next dated row on the same page (the date
    # is often printed beside/below the group); otherwise carry the previous
    # row's date forward. A row with no dated neighbour either side stays blank
    # and remains visibly invalid for the review screen.
    def fill_missing_dates!(transactions)
      transactions.each_with_index do |row, index|
        next if row["date"].present?

        page = row["source_page"]
        next_dated = transactions[(index + 1)..].to_a.find do |candidate|
          candidate["date"].present? && (page.nil? || candidate["source_page"] == page)
        end
        previous_dated = transactions[0...index].to_a.reverse.find { |candidate| candidate["date"].present? }

        source = next_dated || previous_dated
        row["date"] = source["date"] if source
      end
    end

    def format_date_for_import(date_str)
      return "" if date_str.blank?

      date = begin
        Date.parse(date_str.to_s)
      rescue ArgumentError
        parse_date_with_fallbacks(date_str)
      end

      date ? date.strftime(date_format) : date_str.to_s
    end

    def parse_date_with_fallbacks(value)
      [ "%d-%m-%Y", "%d/%m/%Y", "%m-%d-%Y", "%m/%d/%Y", "%Y-%m-%d", "%d %b %Y", "%b %d, %Y" ].each do |format|
        return Date.strptime(value.to_s, format)
      rescue ArgumentError
        next
      end
      nil
    end

    def normalize_amount(value)
      value.to_s.delete("$,").strip
    end

    def account_statement_matches_import
      return if account_statement.blank? ||
                account_statement.family_id == family_id && (account_statement.pdf? || account_statement.image?)

      errors.add(:account_statement, :invalid)
    end
end
