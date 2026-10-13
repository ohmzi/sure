# frozen_string_literal: true

require "digest/md5"
require "digest/sha2"
require "stringio"

class AccountStatement < ApplicationRecord
  include Monetizable

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

  has_many :pdf_imports, -> { where(type: "PdfImport").ordered }, class_name: "PdfImport", dependent: :restrict_with_error
  has_one_attached :original_file, dependent: :purge_later
  # The statement's archived document copy (M8): the native read creates it for
  # the statements it reads; CSV/XLSX/OFX rows have none. The viewer and the tag
  # facet read through it (never destroyed with the statement — the link's
  # history outlives the vault row).
  has_one :archived_document_link, -> { where(source: "statement") }, class_name: "DocumentLink",
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
  scope :unmatched, -> { where(account_id: nil).where(review_status: "unmatched") }
  scope :for_month, ->(month) {
    month_start = month.to_date.beginning_of_month
    month_end = month_start.end_of_month
    where("period_start_on <= ? AND period_end_on >= ?", month_end, month_start)
  }

  # The M1 native statement route stages its own DocumentLink and adopts the
  # vault row onto it. The vault's OWN upload paths (the account tab's
  # statement form, the vault inbox, the OFX import) create only the statement
  # row — so without this the statement is invisible on the unified Documents
  # page, which reads DocumentLink. Mirror the stored bytes into a settled link
  # (Milestone B Task 3, Step 7), so DocumentLink is genuinely the spine every
  # document has. Idempotent: a statement keeps one link, and the native route
  # (already linked) returns it untouched.
  def archive_document_link!(uploader: nil)
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
    # A statement is archived as-is: the vault already read it, so the link
    # settles straight to `unlinked` rather than re-reading the bytes.
    link.transition!(from: "queued", to: "unlinked")
    link.update!(account_statement_id: id)
    link
  end

  class << self
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
        [ statement.id, statement.reconciliation_status(balance_lookup: balance_lookup) ]
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

  def reconciliation_mismatched?(balance_lookup: nil)
    reconciliation_status(balance_lookup: balance_lookup) == "mismatched"
  end

  def reconciliation_checks(balance_lookup: nil)
    return [] unless account.present? && period_start_on.present? && period_end_on.present?

    checks = []
    opening_balance_record = balance_record_for(period_start_on, statement_currency, balance_lookup)
    closing_balance_record = balance_record_for(period_end_on, statement_currency, balance_lookup)

    if opening_balance.present? && opening_balance_record.present?
      checks << reconciliation_check(
        key: "opening_balance",
        statement_amount: opening_balance,
        ledger_amount: opening_balance_record.start_balance
      )
    end

    if closing_balance.present? && closing_balance_record.present?
      checks << reconciliation_check(
        key: "closing_balance",
        statement_amount: closing_balance,
        ledger_amount: closing_balance_record.end_balance
      )
    end

    if opening_balance.present? && closing_balance.present? && opening_balance_record.present? && closing_balance_record.present?
      checks << reconciliation_check(
        key: "period_movement",
        statement_amount: closing_balance - opening_balance,
        ledger_amount: closing_balance_record.end_balance - opening_balance_record.start_balance
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

  private

    def reconciliation_check(key:, statement_amount:, ledger_amount:)
      difference = statement_amount.to_d - ledger_amount.to_d
      {
        key: key,
        statement_amount: statement_amount.to_d,
        ledger_amount: ledger_amount.to_d,
        difference: difference,
        status: difference.abs <= 0.01.to_d ? "matched" : "mismatched"
      }
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
