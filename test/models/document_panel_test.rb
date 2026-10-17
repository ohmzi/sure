require "test_helper"

# The per-document "what I understood" view-model (spec §9): the read, its
# doubts, and what the document became. `understood_receipt_link` carries a
# succeeded extraction fixture; `queued_receipt` has no read at all (the state
# every document is in on a host with no provider configured).
class DocumentPanelTest < ActiveSupport::TestCase
  test "fields carry their confidence and read as unsure when the model was" do
    link = document_links(:understood_receipt_link)
    link.document_extractions.delete_all
    DocumentExtraction.record!(
      document_link: link, provider: "openai", model: "deepseek-flash", ocr_engine: "paddleocr",
      page_count: 1, status: "succeeded", ocr_text: "ACME\nTOTAL 12.34",
      verdict: { "document_class" => "receipt", "total" => "12.34", "payee" => "Acme" },
      field_confidence: { "total" => 0.98, "payee" => 0.31 }
    )

    panel = DocumentPanel.new(link.reload)
    total = panel.fields.find { |f| f.key == "total" }
    payee = panel.fields.find { |f| f.key == "payee" }

    assert_equal "12.34", total.value
    assert_in_delta 0.98, total.confidence, 0.001
    assert_not total.unsure?, "a 0.98 confidence is not a doubt"
    assert payee.unsure?, "a 0.31 confidence must render as unsure, not as a plain value"
  end

  test "an unread document says why rather than showing an empty panel" do
    panel = DocumentPanel.new(document_links(:queued_receipt))

    assert_not panel.read?
    assert panel.empty_reason.present?
  end

  test "the unread reason is the link's own hold when there is one" do
    link = document_links(:queued_receipt)
    # The live host's exact state: no provider, so the read was held with its
    # reason on the link and no extraction row was ever written.
    link.update_columns(failure_message: "no AI provider is configured")

    panel = DocumentPanel.new(link)

    assert_equal "no AI provider is configured", panel.empty_reason
  end

  test "a document being read is not told it cannot be read" do
    # queued_receipt is queued with nothing held and no read yet: the read is in
    # flight. It is NOT unread, and it must never be offered a provider to
    # configure — it is already using one.
    panel = DocumentPanel.new(document_links(:queued_receipt))

    assert panel.reading?, "a queued document with nothing held is being read"
    assert_not panel.read?
    assert_equal I18n.t("documents.understanding.reading_reason"), panel.empty_reason
    assert_no_match(/provider/i, panel.empty_reason)
  end

  test "a pending read row is still 'reading', not 'not read yet'" do
    link = document_links(:queued_receipt)
    DocumentExtraction.record!(document_link: link, provider: "openai", status: "pending")

    panel = DocumentPanel.new(link.reload)

    assert panel.reading?
    assert_no_match(/not read yet/i, panel.empty_reason)
  end

  test "a held read is not 'reading' — it names the hold" do
    link = document_links(:queued_receipt)
    link.update_columns(failure_message: "no AI provider is configured")

    panel = DocumentPanel.new(link)

    assert_not panel.reading?, "a held read is not in flight"
    assert_equal "no AI provider is configured", panel.empty_reason
  end

  test "the latest read is loaded once, not once per reader" do
    link = document_links(:understood_receipt_link)
    latest = link.extraction
    link.expects(:extraction).once.returns(latest)

    panel = DocumentPanel.new(link)

    # Each of these readers used to fire its own SELECT through the link.
    assert panel.shows_panel?
    assert panel.fields.any?
    assert panel.checks.any?
    assert panel.empty_reason.present?
  end

  test "outcomes link to what the document became" do
    panel = DocumentPanel.new(document_links(:understood_receipt_link))

    assert panel.outcomes.all? { |outcome| outcome.url.present? },
           "each outcome must link to the thing it produced (spec §9)"
    draft = panel.outcomes.find { |outcome| outcome.label.match?(/draft/i) }
    assert_match %r{/imports/}, draft.url
  end

  test "the entry outcome links to the entry" do
    panel = DocumentPanel.new(document_links(:linked_receipt))

    entry = panel.outcomes.find { |outcome| outcome.label.match?(/entry/i) }

    assert_not_nil entry
    assert_match %r{/transactions/}, entry.url
  end

  test "outcomes name what the document became" do
    panel = DocumentPanel.new(document_links(:understood_receipt_link))

    assert panel.outcomes.any? { |o| o.label.match?(/receipt|draft/i) }
  end

  test "the viewer splits only when there is a read worth showing" do
    assert_not DocumentPanel.new(document_links(:queued_receipt)).split?
    assert DocumentPanel.new(document_links(:understood_receipt_link)).split?
  end

  test "checks keep the three states apart: pass, not checkable, fail" do
    panel = DocumentPanel.new(document_links(:understood_receipt_link))
    by_label = panel.checks.index_by(&:label)

    assert_equal true, by_label.fetch("OCR and AI agree on the total").state
    assert_nil by_label.fetch("the line items add up to the total").state,
               "a check the pipeline could not run is not a pass"
    assert_equal false, by_label.fetch("the card or account number was found in the page text").state
  end

  test "the panel surfaces a statement whose rows were recovered from line_items" do
    # The fallback is recorded on the read's validations; the panel must show it,
    # so a dropped-then-recovered set of rows is visible to the owner, never silent.
    link = document_links(:understood_receipt_link)
    link.document_extractions.delete_all
    DocumentExtraction.record!(
      document_link: link, provider: "openai", status: "succeeded",
      verdict: { "document_class" => "statement", "institution_name" => "Chase",
                "line_items" => [ { "description" => "ANTHROPIC", "amount" => "-16.52" } ] },
      field_confidence: {},
      validations: { "statement_rows_from_line_items" => true, "statement_rows_have_dates" => false }
    )

    labels = DocumentPanel.new(link.reload).checks.map(&:label)

    assert_includes labels, "the statement rows were read from the line items field"
    assert_includes labels, "every statement row has a date"
  end

  test "a document read but with nothing to say does not split" do
    # A succeeded read whose verdict carried no field the panel knows: it is a
    # read, but it has nothing to say, so the viewer stays a picture.
    link = document_links(:understood_receipt_link)
    link.document_extractions.delete_all
    DocumentExtraction.record!(document_link: link, provider: "openai", status: "succeeded",
                               verdict: {}, field_confidence: {})

    panel = DocumentPanel.new(link.reload)

    assert panel.read?, "a succeeded read is a read"
    assert_not panel.split?, "but with no fields there is nothing worth splitting the viewer for"
  end

  # --- Wave 8: the statement reader's panel checks -----------------------------

  # A trusted reader read's validations (the shape the job writes).
  READER_VALIDATIONS = {
    "statement_rows_from_line_items" => false,
    "statement_rows_have_dates" => true,
    "statement_totals_reconcile" => true,
    "statement_row_count" => 9,
    "statement_rows_missing_dates" => true,
    "statement_rows_source" => "text_layer"
  }.freeze

  test "a trusted reader read shows the checks green and does not double the date check (R-W8B10)" do
    by_label = panel_with_statement_read(READER_VALIDATIONS).checks.index_by(&:label)

    assert_equal true, by_label.fetch("the statement's rows add up to its own totals").state
    assert_equal true, by_label.fetch("no statement row is missing its date").state
    assert_equal true, by_label.fetch("the reader found the statement's rows").state
    assert_equal true, by_label.fetch("the rows were read from the statement's own text layer").state
    assert_nil by_label["every statement row has a date"],
               "the reader's date audit is authoritative for a statement, so the duplicate is not shown"
  end

  test "a held empty read paints the routing checks red and asserts no date property (R-W8B10, must-fix 3)" do
    # The REAL validations a held, empty read produces. The reader found no rows,
    # so the job nils `statement_rows_missing_dates` (must-fix 3): a zero-row read
    # asserts nothing about dates, and `missing_date_rows.empty?` would be
    # vacuously `true` — a green "no statement row is missing its date" beside a
    # red row count. It must be ABSENT, never green (and never the fabricated
    # `false` a red value the job never writes would have painted).
    validations = READER_VALIDATIONS.merge(
      "statement_totals_reconcile" => false,
      "statement_row_count" => 0,
      "statement_rows_missing_dates" => nil
    )
    by_label = panel_with_statement_read(validations).checks.index_by(&:label)

    assert_equal false, by_label.fetch("the statement's rows add up to its own totals").state
    assert_equal false, by_label.fetch("the reader found the statement's rows").state,
                 "a zero row count fails, it is not passed through (R-W8B10)"
    assert_nil by_label["no statement row is missing its date"],
               "a zero-row read asserts no date property, so the check is absent, never green"
    assert_equal true, by_label.fetch("the rows were read from the statement's own text layer").state,
                 "the source is provenance — never red (R-W8B13)"
  end

  test "the reader's source is provenance that names its rung, never red (R-W8B13)" do
    validations = READER_VALIDATIONS.merge("statement_rows_source" => "vision")
    source = panel_with_statement_read(validations).checks.index_by(&:label)
                   .fetch("the rows were read by the AI, checked against the statement's totals")

    assert_equal true, source.state, "a gate-passed read must not render its source red"
  end

  # W8-C makes this source reachable: a scanned statement read from the OCR
  # sidecar's boxes reports `geometry`. The label existed but nothing could
  # produce it, so it had no test.
  test "the geometry source names the layout rung (W8-C)" do
    validations = READER_VALIDATIONS.merge("statement_rows_source" => "geometry")
    source = panel_with_statement_read(validations).checks.index_by(&:label)
                   .fetch("the rows were read from the statement's layout")

    assert_equal true, source.state, "the source is provenance — never red"
  end

  test "the model-fallback path keeps its own date check and shows no reader checks" do
    by_label = panel_with_statement_read(
      "statement_rows_from_line_items" => true, "statement_rows_have_dates" => false
    ).checks.index_by(&:label)

    assert_equal false, by_label.fetch("every statement row has a date").state
    assert_nil by_label["no statement row is missing its date"]
    assert_nil by_label["the statement's rows add up to its own totals"]
    assert_nil by_label["the reader found the statement's rows"]
  end

  # --- W8-G: the panel's labels are localized ----------------------------------

  # The field rows resolve through I18n (documents.understanding.field_labels.*),
  # the same way the checks and sources do. Every label and its mapped value must
  # come out verbatim, so deleting or renaming a key (which renders
  # "translation missing: …") makes by_label.fetch raise here rather than reach the
  # UI. The nine labels are exactly the ones the panel rendered before.
  test "every field label resolves to its exact text, never a missing translation (W8-G)" do
    link = document_links(:understood_receipt_link)
    link.document_extractions.delete_all
    DocumentExtraction.record!(
      document_link: link, provider: "openai", status: "succeeded",
      verdict: {
        "document_class" => "receipt", "institution_name" => "Chase",
        "account_last4" => "1234", "card_last4" => "5678", "card_network" => "Visa",
        "currency" => "USD", "total" => "12.34", "date" => "2026-01-05", "payee" => "Acme"
      },
      field_confidence: {}
    )

    panel = DocumentPanel.new(link.reload)
    by_label = panel.fields.index_by(&:label)

    # The labels a person reads (2026-10-17: sentence case, "Account ending").
    {
      "Type" => "receipt", "Institution" => "Chase", "Account ending" => "1234",
      "Card ending" => "5678", "Card network" => "Visa", "Currency" => "USD",
      "Total" => "12.34", "Date" => "2026-01-05", "Merchant" => "Acme"
    }.each do |label, value|
      assert_equal value, by_label.fetch(label).value, "field #{label.inspect} must render its exact label"
    end

    # Each field carries the verdict key it was built from — the view filters on
    # this (`field.key == "document_class"`), not on the translatable label.
    assert_equal DocumentPanel::FIELD_LABEL_KEYS.keys.sort, panel.fields.map(&:key).sort,
                 "every field must carry its verdict key"

    assert by_label.keys.none? { |label| label.to_s.start_with?("translation missing") },
           "a missing or renamed key must fail here, not in the UI: #{by_label.keys.inspect}"
  end

  # Every label the panel can render resolves through I18n
  # (documents.understanding.check_labels.* / source_labels.*). Each assertion
  # names the exact English the panel showed BEFORE localization, so a missing or
  # renamed key fails here rather than surfacing as "translation missing" in the UI.
  test "every panel label resolves to its exact text, never a missing translation (W8-G)" do
    labels = panel_with_statement_read(READER_VALIDATIONS).checks.map(&:label)

    # the always-on checks
    assert_includes labels, "OCR and AI agree on the total"
    assert_includes labels, "the line items add up to the total"
    assert_includes labels, "the card or account number was found in the page text"
    assert_includes labels, "the date reads as a date"
    # the reader's own statement checks
    assert_includes labels, "no statement row is missing its date"
    assert_includes labels, "the statement's rows add up to its own totals"
    assert_includes labels, "the reader found the statement's rows"
    # the source rung
    assert_includes labels, "the rows were read from the statement's own text layer"

    assert labels.none? { |label| label.to_s.start_with?("translation missing") },
           "a missing or renamed key must fail here, not in the UI: #{labels.inspect}"
  end

  test "the model-fallback checks, every source rung and the unknown-source fallback resolve (W8-G)" do
    fallback = panel_with_statement_read(
      "statement_rows_from_line_items" => true, "statement_rows_have_dates" => false
    ).checks.map(&:label)

    assert_includes fallback, "the statement rows were read from the line items field"
    assert_includes fallback, "every statement row has a date"

    {
      "text_layer" => "the rows were read from the statement's own text layer",
      "geometry" => "the rows were read from the statement's layout",
      "vision" => "the rows were read by the AI, checked against the statement's totals",
      "an_unknown_rung" => "the statement's rows were read"
    }.each do |source, label|
      labels = panel_with_statement_read(READER_VALIDATIONS.merge("statement_rows_source" => source)).checks.map(&:label)

      assert_includes labels, label, "#{source.inspect} must render its exact label"
      assert labels.none? { |rendered| rendered.to_s.start_with?("translation missing") },
             "#{source.inspect} must not render a missing translation: #{labels.inspect}"
    end
  end

  def panel_with_statement_read(validations)
    link = document_links(:understood_receipt_link)
    link.document_extractions.delete_all
    DocumentExtraction.record!(
      document_link: link, provider: "openai", status: "succeeded",
      verdict: { "document_class" => "statement" }, field_confidence: {}, validations: validations
    )
    DocumentPanel.new(link.reload)
  end

  # Spec §6: the viewer shows every reader the read tried, so a stop is never a
  # mystery.
  test "the read history lists each reader, what happened and how long it took" do
    link = document_links(:understood_receipt_link)
    link.document_extractions.delete_all
    DocumentExtraction.record!(
      document_link: link, provider: "DeepSeek", model: "deepseek-flash", page_count: 1, status: "succeeded",
      verdict: { "document_class" => "receipt" },
      validations: { "read_attempts" => [
        { "reader" => "the local model (qwen2.5vl:7b)", "outcome" => "skipped_busy", "seconds" => 0 },
        { "reader" => "DeepSeek", "outcome" => "read", "seconds" => 40.2 }
      ] }
    )

    attempts = DocumentPanel.new(link.reload).attempts

    assert_equal [ "The local model (qwen2.5vl:7b)", "DeepSeek" ], attempts.map(&:reader)
    assert_equal [ "Skipped: the GPU was busy", "Read it" ], attempts.map(&:outcome)
    assert_equal [ nil, "40s" ], attempts.map(&:duration)
  end

  test "a read with no recorded attempts has no history" do
    assert_empty DocumentPanel.new(document_links(:queued_receipt)).attempts
  end

  # Review finding I5 (ruled): rows whose signs were guessed, not proven, go to
  # review — and the panel says so in red, so the owner checks before Import.
  test "a read whose row signs were guessed shows a red signs check" do
    link = document_links(:understood_receipt_link)
    link.document_extractions.delete_all
    %w[keywords undecided flipped as_read].each do |orientation|
      DocumentExtraction.record!(document_link: link, provider: "DeepSeek", page_count: 1, status: "succeeded",
                                 verdict: { "document_class" => "statement" },
                                 validations: { "statement_rows_orientation" => orientation })
      check = DocumentPanel.new(link.reload).checks.find { |candidate| candidate.label == I18n.t("documents.understanding.check_labels.statement_rows_signs_verified") }

      assert check, "the signs check shows for #{orientation}"
      assert_equal orientation.in?(%w[flipped as_read]), check.state, orientation
      link.document_extractions.delete_all
    end
  end
end
