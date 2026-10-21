# frozen_string_literal: true

require "digest/md5"
require "digest/sha2"
require "stringio"

class AccountStatement < ApplicationRecord
  include Monetizable, Auditable

  # Financial identity and reconciliation figures. Hints, filenames and the
  # review acknowledgement are not money edits and are recorded explicitly by
  # the controller that changes them.
  audit_financial_attributes :account_id, :period_start_on, :period_end_on,
                             :opening_balance, :closing_balance, :currency

  DuplicateUploadError = Class.new(StandardError) do
    attr_reader :statement

    def initialize(statement)
      @statement = statement
      super("Statement file has already been uploaded")
    end
  end
  InvalidUploadError = Class.new(StandardError)

  PreparedUpload = Data.define(:content, :filename, :content_type, :byte_size, :checksum, :content_sha256)

  MAX_FILE_SIZE = 25.megabytes
  READ_CHUNK_SIZE = 1.megabyte
  # The data-quality asks the Documents attention strip counts and the vault's
  # q[attention] filter lists. Precedence order: a held statement owns
  # "couldn't be read", then an unmatched one owns "needs an account", and only
  # then do the metadata asks apply.
  ATTENTION_REASONS = %w[held_or_failed unmatched missing_period missing_identity].freeze
  ALLOWED_EXTENSION_CONTENT_TYPES = {
    ".pdf" => %w[application/pdf],
    ".csv" => %w[text/csv text/plain application/csv application/vnd.ms-excel],
    ".xlsx" => %w[application/vnd.openxmlformats-officedocument.spreadsheetml.sheet],
    # OFX/QFX archive in the Statement Vault for provenance (spec §8.2). marcel
    # has no `ofx` entry, but 1.2.1 maps `qfx => application/vnd.intu.qfx`, so a
    # .qfx whose OS/declared type is absent or octet-stream resolves to that and
    # must be listed here or allowed_upload? raises InvalidUploadError. The set
    # spans the declared and sniffed possibilities for both extensions.
    ".ofx" => %w[application/vnd.intu.qfx application/x-ofx text/xml application/xml text/plain application/octet-stream],
    ".qfx" => %w[application/vnd.intu.qfx application/x-ofx text/xml application/xml text/plain application/octet-stream],
    # M7 (locked decision 9): a camera photo of a statement is a first-class
    # vault upload. Types are the Task-1 probe's Marcel results (real magic
    # bytes: JPEG/PNG signatures, ISO-BMFF `ftypheic`/`ftypmif1`); the wizard
    # posts the bytes unchanged.
    ".jpg" => %w[image/jpeg],
    ".jpeg" => %w[image/jpeg],
    ".png" => %w[image/png],
    ".heic" => %w[image/heic],
    ".heif" => %w[image/heif]
  }.freeze
  ALLOWED_CONTENT_TYPES = ALLOWED_EXTENSION_CONTENT_TYPES.values.flatten.uniq.freeze
  ACCEPTED_FILE_EXTENSIONS = ALLOWED_EXTENSION_CONTENT_TYPES.keys.freeze

  belongs_to :family
  belongs_to :account, optional: true
  belongs_to :suggested_account, class_name: "Account", optional: true
  # A person who has checked this statement by hand. Reconciliation checks stay
  # factual; the acknowledgement is a separate fact.
  belongs_to :reviewed_by, class_name: "User", optional: true

  has_many :pdf_imports, -> { where(type: "PdfImport").ordered }, class_name: "PdfImport", dependent: :restrict_with_error
  has_one_attached :original_file, dependent: :purge_later
  # The statement's archived document copy (M8): the native read creates it for
  # the statements it reads; CSV/XLSX/OFX rows have none. The viewer and the tag
  # facet read through it (never destroyed with the statement — the link's
  # history outlives the vault row).
  # A soft-deleted link is history, not the statement's archived copy. Keeping
  # deleted rows out of this association is what makes `archive_document_link!`
  # able to restore a document whose copy the duplicate review deleted.
  has_one :archived_document_link, -> { where(source: "statement", deleted_at: nil) }, class_name: "DocumentLink",
          foreign_key: :account_statement_id, dependent: nil

  enum :source, { manual_upload: "manual_upload" }, validate: true, default: "manual_upload"
  enum :upload_status, { stored: "stored", failed: "failed" }, validate: true, default: "stored"
  # The statement's extraction outcome: the native read sets `extracted` once it
  # has read the statement. `extraction_failed` avoids colliding with the
  # upload_status `failed` helper.
  enum :extraction_state, {
    not_attempted: "not_attempted",
    processing: "processing",
    extracted: "extracted",
    extraction_failed: "extraction_failed"
  }, validate: true, default: "not_attempted", scopes: false
  enum :review_status, { unmatched: "unmatched", linked: "linked", rejected: "rejected" }, validate: true, default: "unmatched", scopes: false

  monetize :opening_balance, :closing_balance

  before_validation :sync_file_metadata, if: -> { original_file.attached? }
  before_validation :normalize_currency
  before_validation :sync_review_status

  validates :filename, :content_type, :checksum, presence: true
  validates :byte_size, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: MAX_FILE_SIZE }
  validates :content_type, inclusion: { in: ALLOWED_CONTENT_TYPES }
  validates :content_sha256,
            format: { with: /\A[0-9a-f]{64}\z/ },
            uniqueness: { scope: :family_id, allow_nil: true, message: :duplicate_statement_file },
            allow_nil: true
  validates :parser_confidence, :match_confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validate :account_belongs_to_family
  validate :suggested_account_belongs_to_family
  validate :period_order
  validate :currency_is_valid
  validate :filename_extension_matches_content_type
  validate :original_file_attached
  validate :original_file_constraints, if: -> { original_file.attached? }

  scope :ordered, -> { order(created_at: :desc) }
  scope :with_account, -> { where.not(account_id: nil) }
  # A statement whose only archived document was deleted (the duplicate review's
  # Delete) is a tombstone: keep the row for history, but do not let it count as
  # a second statement for the month. A statement with no document link at all
  # (a vault-only upload) is still real and stays.
  scope :excluding_tombstones, -> {
    where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM document_links deleted_links
        WHERE deleted_links.account_statement_id = account_statements.id
          AND deleted_links.deleted_at IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM document_links live_links
            WHERE live_links.account_statement_id = account_statements.id
              AND live_links.deleted_at IS NULL
          )
      )
    SQL
  }
  scope :unmatched, -> { where(account_id: nil).where(review_status: "unmatched") }
  # Data-quality asks (P1.11): a statement whose stored period is incomplete,
  # and one with no printed identity to match an account by. Both are facts the
  # owner can fix on the statement page, so the attention strip counts them.
  scope :missing_period, -> { where("period_start_on IS NULL OR period_end_on IS NULL") }
  # The SQL twin of #printed_identity? must agree with it on blank values: a
  # whitespace-only hint is not an identity, and an array of blank strings is
  # not a printed number.
  scope :with_printed_identity, -> {
    where(<<~SQL.squish)
      btrim(COALESCE(account_statements.account_last4_hint, ''), E' \\t\\n\\r') <> ''
      OR btrim(COALESCE(account_statements.institution_name_hint, ''), E' \\t\\n\\r') <> ''
      OR btrim(COALESCE(account_statements.account_name_hint, ''), E' \\t\\n\\r') <> ''
      OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(
          CASE
            WHEN jsonb_typeof(account_statements.sanitized_parser_output -> 'printed_last4s') = 'array'
            THEN account_statements.sanitized_parser_output -> 'printed_last4s'
            ELSE '[]'::jsonb
          END
        ) AS printed_last4(value)
        WHERE btrim(printed_last4.value, E' \\t\\n\\r') <> ''
      )
    SQL
  }
  scope :missing_printed_identity, -> { where.not(id: with_printed_identity.select(:id)) }
  scope :incomplete_metadata, -> { missing_period.or(missing_printed_identity) }
  # The per-user vault visibility rule, shared by the statements list and the
  # attention strip: a count must never include a statement the list hides.
  scope :visible_to, ->(user) {
    user ? where(account_id: nil).or(where(account_id: user.accessible_accounts.select(:id))) : all
  }
  # Rejecting a suggestion leaves the statement accountless, so it stays in the inbox where it can be found and deleted.
  scope :inbox, -> { where(account_id: nil).where(review_status: %w[unmatched rejected]) }
  scope :for_month, ->(month) {
    month_start = month.to_date.beginning_of_month
    month_end = month_start.end_of_month
    where("period_start_on <= ? AND period_end_on >= ?", month_end, month_start)
  }

  # The M1 native statement route stages its own DocumentLink and adopts the
  # vault row onto it. The other upload paths (the account tab's statement
  # form, the Documents dropzone, the OFX import) create only the statement
  # row — so without this the statement is invisible on the unified Documents
  # page, which reads DocumentLink. Mirror the stored bytes into a settled link
  # (Milestone B Task 3, Step 7), so DocumentLink is genuinely the spine every
  # document has. Idempotent: a statement keeps one link, and the native route
  # (already linked) returns it untouched.
  def archive_document_link!(uploader: nil, process: false)
    return archived_document_link if archived_document_link.present?

    link = DocumentLink.link_from_upload!(family: family, uploader: uploader,
                                          source: "statement", title: filename)
    begin
      DocumentLink.transaction(requires_new: true) do
        original_file.blob.open do |io|
          link.stage!(io: io, filename: filename, content_type: content_type)
        end
      end
    rescue StandardError
      # stage! failed after the row existed: reclaim the bytes and drop the row
      # rather than leave a byte-less link that can never progress (the intake's
      # own cleanup shape).
      DocumentLink::Staging.delete(link.id.to_s)
      link.destroy!
      raise
    end
    link.update!(account_statement_id: id)

    if process && native_readable?
      # The vault's own upload path has NOT read the bytes. Leave the link
      # queued and hand it to the native reader; the row and the staged file
      # make the read recoverable if the enqueue or the worker is lost.
      DocumentUnderstandingJob.perform_later(link.id)
    else
      # A statement read elsewhere (the native route) is archived as-is; a
      # CSV/OFX upload has no page for the native reader, so it settles here.
      link.transition!(from: "queued", to: "unlinked")
    end
    link
  end

  # The native reader handles page documents: a PDF's pages and an image. A
  # vault upload may also be a CSV/OFX bank export, which has no page to OCR and
  # is imported through its own path.
  def native_readable?
    content_type == "application/pdf" || content_type.to_s.start_with?("image/")
  end

  class << self
    # One authority for the data-quality asks. The Documents attention strip
    # counts these relations; the vault's q[attention] filter lists exactly the
    # same rows, so a count and the list its button opens cannot disagree.
    # Returns nil for an unknown reason (the filter then applies nothing).
    def attention_scope(reason, family:)
      case normalize_attention_reason(reason)
      when "held_or_failed" then attention_actionable(family).where(id: attention_held_link_ids(family))
      when "unmatched" then attention_unmatched_scope(family)
      when "missing_period" then attention_missing_period_scope(family)
      when "missing_identity" then attention_missing_identity_scope(family)
      end
    end

    def statement_manager?(user)
      user&.admin? || user&.member?
    end

    # Statement search over the statement's own filename OR the OCR snapshot of
    # its linked document (a statement without a link still matches by name —
    # the fallback). Local only: never an external call (M8 locked decision 4 /
    # M7 Task 10's pin, kept verbatim in behaviour).
    def search(query)
      term = query.to_s.strip
      return all if term.blank?

      pattern = "%#{sanitize_sql_like(term)}%"
      matching_links = DocumentLink.where(source: "statement")
                                   .where("extracted_text ILIKE :p OR title ILIKE :p OR original_filename ILIKE :p", p: pattern)
                                   .where.not(account_statement_id: nil)
      where("account_statements.filename ILIKE :p", p: pattern)
        .or(where(id: matching_links.select(:account_statement_id)))
    end

    def create_from_upload!(family:, account:, file:)
      prepared_upload = prepare_upload!(file)
      create_from_prepared_upload!(family: family, account: account, prepared_upload: prepared_upload)
    end

    def create_from_prepared_upload!(family:, account:, prepared_upload:)
      statement = nil
      duplicate = duplicate_for(family, prepared_upload)
      raise DuplicateUploadError, duplicate if duplicate

      statement = family.account_statements.build(
        account: account,
        filename: prepared_upload.filename,
        content_type: prepared_upload.content_type,
        byte_size: prepared_upload.byte_size,
        checksum: prepared_upload.checksum,
        content_sha256: prepared_upload.content_sha256,
        source: :manual_upload,
        upload_status: :stored,
        review_status: account.present? ? :linked : :unmatched,
        currency: account&.currency || family.currency
      )

      statement.original_file.attach(
        io: StringIO.new(prepared_upload.content),
        filename: prepared_upload.filename,
        content_type: prepared_upload.content_type
      )

      MetadataDetector.new(statement, content: prepared_upload.content).apply

      # The printed period is known only after metadata detection. Two downloads
      # of one statement differ in their PDF metadata, so content_sha256 misses
      # the duplicate; period + account (or the card/account last4) is the
      # statement's identity. One account cannot have two statements for one
      # cycle, so a later copy must reuse the existing row.
      duplicate = semantic_duplicate_for(family, statement)
      raise DuplicateUploadError, duplicate if duplicate

      statement.assign_account_match unless account.present?
      statement.save!
      statement
    rescue ActiveRecord::RecordNotUnique
      duplicate = duplicate_for(family, prepared_upload)
      purge_original_file(statement)

      if duplicate
        raise DuplicateUploadError, duplicate
      end

      raise
    rescue StandardError
      purge_original_file(statement)
      raise
    end

    def reconciliation_statuses_for(statements, account:)
      statement_list = statements.to_a
      balance_lookup = balance_lookup_for(account, statement_list)

      statement_list.to_h do |statement|
        status = statement.reviewed? ? "reviewed" : statement.reconciliation_status(balance_lookup: balance_lookup)
        [ statement.id, status ]
      end
    end

    def prepare_upload!(file)
      filename = file.original_filename.to_s
      content = read_upload_content!(file)
      byte_size = content.bytesize
      raise InvalidUploadError if byte_size.zero?

      content_type = detected_content_type(content:, filename:, declared_content_type: file.content_type)
      raise InvalidUploadError unless allowed_upload?(filename:, content_type:)
      raise InvalidUploadError if content_type == "application/pdf" && !valid_pdf_content?(content)

      PreparedUpload.new(
        content: content,
        filename: filename,
        content_type: content_type,
        byte_size: byte_size,
        checksum: Digest::MD5.base64digest(content),
        content_sha256: Digest::SHA256.hexdigest(content)
      )
    end

    def detected_content_type(content:, filename:, declared_content_type:)
      Marcel::MimeType.for(
        StringIO.new(content),
        name: filename,
        declared_type: declared_content_type.presence
      )
    end

    def allowed_upload?(filename:, content_type:)
      allowed_content_types_for_filename(filename).include?(content_type)
    end

    def allowed_content_types_for_filename(filename)
      ALLOWED_EXTENSION_CONTENT_TYPES.fetch(File.extname(filename.to_s).downcase, [])
    end

    def valid_pdf_content?(content)
      content.start_with?("%PDF-")
    end

    def purge_original_file(statement)
      return unless statement&.original_file&.attached?

      statement.original_file.purge
    rescue StandardError => e
      Rails.logger.warn("AccountStatement staged blob cleanup failed: #{e.class}: #{e.message}")
    end

    def balance_lookup_for(account, statements)
      currencies = statements.map(&:statement_currency).compact.uniq
      dates = statements.flat_map { |statement| [ statement.period_start_on, statement.period_end_on ] }.compact.uniq
      balances = if currencies.any? && dates.any?
        account.balances.where(currency: currencies, date: dates).to_a
      else
        []
      end
      balances_by_key = balances.index_by { |balance| [ balance.date, balance.currency ] }

      ->(date, currency) { balances_by_key[[ date, currency ]] }
    end

    def read_upload_content!(file)
      declared_size = declared_upload_size(file)
      raise InvalidUploadError if declared_size.present? && declared_size > MAX_FILE_SIZE

      content = +"".b
      loop do
        chunk = file.read(READ_CHUNK_SIZE)
        break if chunk.nil? || chunk.empty?

        content << chunk
        raise InvalidUploadError if content.bytesize > MAX_FILE_SIZE
      end

      file.rewind if file.respond_to?(:rewind)
      content
    end

    def declared_upload_size(file)
      if file.respond_to?(:size)
        file.size
      elsif file.respond_to?(:length)
        file.length
      end
    end

    def duplicate_for(family, prepared_upload)
      scope = family.account_statements
      sha_duplicate = scope.find_by(content_sha256: prepared_upload.content_sha256) if prepared_upload.content_sha256.present?
      return sha_duplicate if sha_duplicate

      # Active Storage's MD5 checksum is retained only to catch legacy rows that predate content_sha256.
      legacy_scope = prepared_upload.content_sha256.present? ? scope.where(content_sha256: nil) : scope
      legacy_scope.find_by(checksum: prepared_upload.checksum)
    end

    # The same statement downloaded twice has different bytes (PDF metadata
    # embeds a timestamp), so the content hashes disagree while the document is
    # identical. Its identity is the printed period plus the account it belongs
    # to — or, for an unmatched upload, the card/account last4. One account
    # cannot have two statements covering one cycle; the later copy reuses the
    # row (and the caller can restore its document).
    def semantic_duplicate_for(family, statement)
      return nil unless statement.period_start_on.present? && statement.period_end_on.present?
      # Without an account or an account/card identifier the period alone cannot
      # tell two bank statements apart.
      return nil if statement.account_id.blank? && statement.account_last4_hint.blank?

      scope = family.account_statements.where(
        period_start_on: statement.period_start_on,
        period_end_on: statement.period_end_on
      )
      # An unmatched original is still the same statement once the account is
      # picked, so include it; a different account is a different statement.
      scope = scope.where(account_id: [ statement.account_id, nil ]) if statement.account_id.present?

      scope.order(:created_at).find do |existing|
        same_identifier = statement.account_last4_hint.present? &&
                          existing.account_last4_hint.present? &&
                          existing.account_last4_hint == statement.account_last4_hint
        same_identifier || normalized_statement_name(existing.filename) == normalized_statement_name(statement.filename)
      end
    end

    # Browser/download copies append "-2", "-3", " (1)" and the like. Strip the
    # copy suffix, never a date component ("...2026-06-12" is part of the
    # statement's identity, not a copy number).
    def normalized_statement_name(filename)
      name = File.basename(filename.to_s, ".*").squish
      name = name.sub(/\s*\(\d+\)\z/, "")
      name = name.sub(/[-_ ]\d{1,2}\z/, "") unless name.match?(/\d{4}[-_]\d{1,2}\z/) || name.match?(/\d{4}[-_]\d{1,2}[-_]\d{1,2}\z/)
      name.downcase
    end

    private

      def normalize_attention_reason(reason)
        value = reason.to_s
        value = "missing_identity" if value == "missing_printed_identity"
        value = "held_or_failed" if value.in?(%w[couldnt_read held failed])
        value = "unmatched" if value == "needs_account"
        value if ATTENTION_REASONS.include?(value)
      end

      # The statements list and the documents filter both drop a tombstoned row
      # (whose only document link was soft-deleted). The attention authority
      # composes the same exclusion, so a count can never include a row its
      # list hides. A rejected statement is not waiting on anyone.
      def attention_actionable(family)
        family.account_statements.excluding_tombstones.where.not(review_status: "rejected")
      end

      # A live document whose read stopped with a reason. The link's family is
      # pinned to the statement's family as defense in depth; the strip's
      # "couldn't read" branch makes the same held-link test.
      def attention_held_link_ids(family)
        DocumentLink.where(family: family, deleted_at: nil)
                    .where.not(failure_message: nil)
                    .where.not(account_statement_id: nil)
                    .select(:account_statement_id)
      end

      def attention_unmatched_scope(family)
        attention_actionable(family).unmatched
          .where.not(id: attention_held_link_ids(family))
      end

      def attention_missing_period_scope(family)
        attention_actionable(family).missing_period
          .where.not(id: attention_held_link_ids(family))
          .where.not(id: attention_unmatched_scope(family).select(:id))
      end

      def attention_missing_identity_scope(family)
        actionable = attention_actionable(family)
        # Build the identity subquery from the family-scoped relation (rather
        # than the generic scope) so every nested statement query carries the
        # family predicate too.
        actionable.where.not(id: actionable.with_printed_identity.select(:id))
          .where.not(id: attention_held_link_ids(family))
          .where.not(id: attention_unmatched_scope(family).select(:id))
          .where.not(id: actionable.missing_period.select(:id))
      end
  end

  def viewable_by?(user)
    return false unless user&.family_id == family_id

    account.present? ? account.shared_with?(user) : self.class.statement_manager?(user)
  end

  def manageable_by?(user)
    return false unless user&.family_id == family_id

    return self.class.statement_manager?(user) if account.blank?

    account.permission_for(user).in?([ :owner, :full_control ]) && self.class.statement_manager?(user)
  end

  def link_to_account!(target_account, confidence: 1.0)
    update!(
      account: target_account,
      suggested_account: nil,
      match_confidence: confidence,
      review_status: :linked,
      currency: currency.presence || target_account.currency
    )
  end

  # A statement with no account a person has NOT already rejected. The one
  # predicate behind the tile's "Which account?" state, the "needs you" strip's
  # "needs an account" count and the picker's render gate, so the three surfaces
  # can never disagree about whether this statement is waiting on someone.
  def needs_account?
    account_id.nil? && !rejected?
  end

  def missing_period?
    period_start_on.blank? || period_end_on.blank?
  end

  # The identity the statement itself gives: a printed card/account number, a
  # bank name, or the filename hint. With none of these, nothing can match the
  # statement to an account automatically.
  def printed_identity?
    printed_last4s = sanitized_parser_output.to_h["printed_last4s"]

    account_last4_hint.present? ||
      institution_name_hint.present? ||
      account_name_hint.present? ||
      (printed_last4s.is_a?(Array) && printed_last4s.compact_blank.any?)
  end

  def missing_printed_identity? = !printed_identity?

  # The metadata the owner can supply on this page. A rejected statement is not
  # waiting on anyone, and a held/failed read owns the "couldn't be read" ask,
  # so neither is offered as a details ask (the strip makes the same split).
  def needs_details?
    !rejected? &&
      archived_document_link&.failure_message.blank? &&
      (missing_period? || missing_printed_identity?)
  end

  # P1.11: a disagreement between the stored period and the filename/printed
  # period is a warning on the record, never an automatic rewrite.
  def period_warning
    return @period_warning if defined?(@period_warning)

    @period_warning = AccountStatement::PeriodCheck.new(self).warning
  end

  def period_looks_wrong? = period_warning.present?
  def period_warning_message = period_warning&.message

  def unlink!
    transaction do
      update!(
        account: nil,
        review_status: :unmatched,
        match_confidence: nil
      )
      assign_account_match
      save!
    end
  end

  def reject_match!
    update!(
      suggested_account: nil,
      match_confidence: nil,
      review_status: :rejected
    )
  end

  def assign_account_match
    match = AccountMatcher.new(self).best_match

    self.suggested_account = match&.account
    self.match_confidence = match&.confidence
    clear_invalid_suggested_account
  end

  def covered_months
    return [] unless period_start_on.present? && period_end_on.present?

    current = period_start_on.beginning_of_month
    last = period_end_on.beginning_of_month
    months = []

    while current <= last
      months << current
      current = current.next_month
    end

    months
  end

  def covers_month?(month)
    covered_months.include?(month.to_date.beginning_of_month)
  end

  def reconciliation_status(balance_lookup: nil)
    checks = reconciliation_checks(balance_lookup: balance_lookup)
    return "unavailable" if checks.empty?

    checks.any? { |check| check[:status] == "mismatched" } ? "mismatched" : "matched"
  end

  def reviewed? = reviewed_at.present?

  # --- overlap review hint (P1.7) -------------------------------------------
  # Consecutive monthly statements share exactly the boundary day: one ends
  # where the next begins. That is normal. Two statements sharing MORE than
  # that day while printing different balances are the shape of a duplicate
  # upload with a wrong period, or a misread. Strict inside-comparisons are what
  # keep the ordinary adjacency out; the balance comparison lives here, never
  # in a view.
  def overlapping_balance_mismatches
    return self.class.none unless account_id.present? && period_start_on.present? && period_end_on.present?

    account.account_statements
           .excluding_tombstones
           .where.not(id: id)
           .where("period_start_on < ? AND period_end_on > ?", period_end_on, period_start_on)
           .select { |other| printed_balance_mismatch?(other) }
  end

  def overlapping_balance_mismatch?(other)
    return false unless other && other.id != id
    return false unless account_id.present? && other.account_id == account_id
    return false unless period_start_on.present? && period_end_on.present? &&
                        other.period_start_on.present? && other.period_end_on.present?
    return false unless other.period_start_on < period_end_on && other.period_end_on > period_start_on

    printed_balance_mismatch?(other)
  end

  def reconciliation_mismatched?(balance_lookup: nil)
    reconciliation_status(balance_lookup: balance_lookup) == "mismatched"
  end

  def reconciliation_checks(balance_lookup: nil)
    return [] unless account.present? && period_start_on.present? && period_end_on.present?
    # A statement whose rows are in Sure is verified by them (the owner keeps
    # card rows on their purchase date, which straddles statement boundaries).
    return row_reconciliation_checks(balance_lookup) if row_checkable?

    checks = []
    opening_balance_record = balance_record_for(period_start_on, statement_currency, balance_lookup)
    closing_balance_record = balance_record_for(period_end_on, statement_currency, balance_lookup)

    # Where the period opens depends on the layout of the statements around it.
    # When a preceding statement ended on (or before) this period's first day,
    # the printed opening is its closing balance: on a shared boundary day that
    # is the END of the day (the day's activity belongs to the previous
    # statement); the day after, it is the same figure as the start of this
    # period's first day. Only with no preceding statement does the day's
    # opening anchor/start balance have to stand in.
    #
    # Comparing with end_balance unconditionally was wrong for the day-before
    # layout (Apr 13–May 12, then May 13–Jun 12): the balance record's end of
    # May 13 already includes the new statement's own first-day activity.
    previous = neighbour(before: true)
    opening_ledger = previous&.closing_balance
    opening_ledger ||= account.opening_anchor_balance if account.has_opening_anchor?
    opening_ledger ||= opening_balance_record&.start_balance

    if opening_balance.present? && opening_ledger.present?
      checks << reconciliation_check(
        key: "opening_balance",
        statement_amount: opening_balance,
        ledger_amount: opening_ledger
      )
    end

    if closing_balance.present? && closing_balance_record.present?
      checks << reconciliation_check(
        key: "closing_balance",
        statement_amount: closing_balance,
        ledger_amount: closing_balance_record.end_balance
      )
    end

    if opening_balance.present? && closing_balance.present? && opening_ledger.present? && closing_balance_record.present?
      checks << reconciliation_check(
        key: "period_movement",
        statement_amount: closing_balance - opening_balance,
        ledger_amount: closing_balance_record.end_balance - opening_ledger
      )
    end

    checks
  end

  def statement_currency
    currency.presence || account&.currency || family.currency
  end

  def pdf?
    content_type.in?(ALLOWED_EXTENSION_CONTENT_TYPES[".pdf"])
  end

  def csv?
    content_type.in?(ALLOWED_EXTENSION_CONTENT_TYPES[".csv"])
  end

  def xlsx?
    content_type.in?(ALLOWED_EXTENSION_CONTENT_TYPES[".xlsx"])
  end

  def ofx?
    content_type.in?(ALLOWED_EXTENSION_CONTENT_TYPES[".ofx"]) ||
      content_type.in?(ALLOWED_EXTENSION_CONTENT_TYPES[".qfx"])
  end

  def image?
    content_type.in?(ALLOWED_EXTENSION_CONTENT_TYPES[".jpg"]) ||
      content_type.in?(ALLOWED_EXTENSION_CONTENT_TYPES[".jpeg"]) ||
      content_type.in?(ALLOWED_EXTENSION_CONTENT_TYPES[".png"]) ||
      content_type.in?(ALLOWED_EXTENSION_CONTENT_TYPES[".heic"]) ||
      content_type.in?(ALLOWED_EXTENSION_CONTENT_TYPES[".heif"])
  end

  def latest_reusable_pdf_import
    pdf_imports.where.not(status: :failed).order(created_at: :desc).first
  end

  # A statement may only be deleted as an unimported whole. The import owns the
  # rows it posted; deleting the statement under it would orphan that import.
  # The archived document is the surviving evidence and obeys the same N9 rule
  # as the document browser: it must not cover unreconciled entries.
  def deletion_blocker
    return :imports if pdf_imports.exists? || Entry.reconciled_by(self).exists?
    return :document if archived_document_link.present? && !archived_document_link.deletable?

    nil
  end

  def deletable? = deletion_blocker.nil?

  private

    def audit_currency
      statement_currency
    end

    # Balances a statement actually prints. A missing balance is not evidence
    # of a mismatch, and a cent of rounding is not a disagreement.
    def printed_balance_mismatch?(other)
      pairs = [ [ opening_balance, other.opening_balance ], [ closing_balance, other.closing_balance ] ]
      comparable = pairs.select { |mine, theirs| mine.present? && theirs.present? }

      comparable.any? { |mine, theirs| (mine.to_d - theirs.to_d).abs > 0.01.to_d }
    end

    def statement_rows
      Entry.reconciled_by(self).where(account_id: account_id).where.not(entryable_type: "Valuation")
    end

    def row_checkable?
      opening_balance.present? && closing_balance.present? && statement_rows.exists?
    end

    # The statement checked by its own rows and its neighbours, not by daily
    # balances at its boundary dates:
    #   * period movement — opening + its rows = closing (a liability rises with
    #     an outflow, an asset falls);
    #   * opening — the previous statement's closing (else the account's opening
    #     balance when this statement is its earliest);
    #   * closing — the next statement's opening (else the ledger on the last day).
    def row_reconciliation_checks(balance_lookup)
      flow = statement_rows.sum(:amount)
      movement = account.classification == "liability" ? flow : -flow
      checks = [ reconciliation_check(key: "period_movement", statement_amount: closing_balance - opening_balance,
                                      ledger_amount: movement) ]

      previous = neighbour(before: true)
      opening_ledger = previous ? previous.closing_balance : (account.opening_anchor_balance if account.has_opening_anchor?)
      checks.unshift(reconciliation_check(key: "opening_balance", statement_amount: opening_balance, ledger_amount: opening_ledger)) if opening_ledger

      following = neighbour(before: false)
      closing_ledger = following ? following.opening_balance : balance_record_for(period_end_on, statement_currency, balance_lookup)&.end_balance
      checks.insert(1, reconciliation_check(key: "closing_balance", statement_amount: closing_balance, ledger_amount: closing_ledger)) if closing_ledger
      checks
    end

    def neighbour(before:)
      scope = account.account_statements.where.not(id: id)
      if before
        scope.where(period_end_on: ..period_start_on).where.not(closing_balance: nil).order(period_end_on: :desc).first
      else
        scope.where(period_start_on: (period_end_on)..).where.not(opening_balance: nil).order(:period_start_on).first
      end
    end

    def reconciliation_check(key:, statement_amount:, ledger_amount:)
      difference = statement_amount.to_d - ledger_amount.to_d
      status = difference.abs <= 0.01.to_d ? "matched" : "mismatched"
      check = {
        key: key,
        statement_amount: statement_amount.to_d,
        ledger_amount: ledger_amount.to_d,
        difference: difference,
        status: status
      }
      check[:explanation] = reconciliation_explanation(key, statement_amount, ledger_amount, difference) if status == "mismatched"
      check
    end

    # A failed check must say what disagreed, not only that it did. The wording
    # lives here (not in the view) so every consumer reads the same sentence.
    def reconciliation_explanation(key, statement_amount, ledger_amount, difference)
      I18n.t(
        "account_statements.reconciliation.explanations.#{key}",
        default: I18n.t("account_statements.reconciliation.explanations.default"),
        statement: reconciliation_amount_label(statement_amount),
        ledger: reconciliation_amount_label(ledger_amount),
        difference: reconciliation_amount_label(difference.abs)
      )
    end

    def reconciliation_amount_label(amount)
      Money.new(amount.to_d, statement_currency).format
    rescue Money::Currency::UnknownCurrencyError, ArgumentError
      ActiveSupport::NumberHelper.number_to_currency(amount.to_d, unit: statement_currency)
    end

    def balance_record_for(date, currency, balance_lookup)
      return balance_lookup.call(date, currency) if balance_lookup

      account.balances.find_by(date: date, currency: currency)
    end

    def sync_file_metadata
      blob = original_file.blob
      self.filename ||= blob.filename.to_s
      self.content_type ||= blob.content_type
      self.byte_size ||= blob.byte_size
      self.checksum ||= blob.checksum
    end

    def normalize_currency
      self.currency = currency.to_s.upcase.presence if currency.present?
    end

    def sync_review_status
      return if rejected?

      self.review_status = "linked" if account.present? && !linked?
      self.review_status = "unmatched" if account.blank? && linked?
    end

    def account_belongs_to_family
      return if account.nil?
      return if account.family_id == family_id

      errors.add(:account, :invalid)
    end

    def suggested_account_belongs_to_family
      return if suggested_account_valid_for_family?

      errors.add(:suggested_account, :invalid)
    end

    def clear_invalid_suggested_account
      return if suggested_account_valid_for_family?

      self.suggested_account = nil
      self.match_confidence = nil
    end

    def suggested_account_valid_for_family?
      suggested_account.nil? || suggested_account.family_id == family_id
    end

    def period_order
      return if period_start_on.blank? || period_end_on.blank?
      return if period_start_on <= period_end_on

      errors.add(:period_end_on, :on_or_after_start)
    end

    def currency_is_valid
      return if currency.blank?

      Money::Currency.new(currency)
    rescue Money::Currency::UnknownCurrencyError, ArgumentError
      errors.add(:currency, :invalid)
    end

    def filename_extension_matches_content_type
      return if filename.blank? || content_type.blank?
      return if self.class.allowed_upload?(filename: filename, content_type: content_type)

      errors.add(:content_type, :invalid)
    end

    def original_file_constraints
      if original_file.byte_size.zero?
        errors.add(:original_file, :blank)
      elsif original_file.byte_size > MAX_FILE_SIZE
        errors.add(:original_file, :too_large, max_mb: MAX_FILE_SIZE / 1.megabyte)
      end

      unless self.class.allowed_upload?(filename: original_file.filename.to_s, content_type: original_file.content_type)
        errors.add(:original_file, :invalid_format, file_format: original_file.content_type)
      end
    end

    def original_file_attached
      errors.add(:original_file, :blank) unless original_file.attached?
    end
end
