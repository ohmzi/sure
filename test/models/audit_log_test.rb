require "test_helper"

class AuditLogTest < ActiveSupport::TestCase
  setup do
    Current.reset
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @entry = entries(:transaction)
    @transaction = @entry.transaction
  end

  teardown { Current.reset }

  test "records the actor, request id and the changed financial fields" do
    Current.session = sessions(:one)
    Current.request_id = "request-123"
    Current.audit_source = "web"

    assert_difference -> { AuditLog.count }, 1 do
      @transaction.update!(category: categories(:income))
    end

    log = AuditLog.order(:created_at).last

    assert_equal @family, log.family
    assert_equal @user, log.actor
    assert_equal "transaction.updated", log.action
    assert_equal "request-123", log.request_id
    assert_equal({ "source" => "web" }, log.metadata.slice("source"))

    assert_equal categories(:food_and_drink).id, log.before["category_id"]
    assert_equal "Food & Drink", log.before["category_name"]
    assert_equal categories(:income).id, log.after["category_id"]
    assert_equal "Income", log.after["category_name"]
  end

  test "records amount and date changes on the entry against its transaction" do
    Current.session = sessions(:one)
    Current.request_id = "request-456"
    Current.audit_source = "web"

    assert_difference -> { AuditLog.count }, 1 do
      @entry.update!(amount: 42, date: Date.current)
    end

    log = AuditLog.order(:created_at).last

    assert_equal @transaction, log.auditable
    assert_equal @family, log.family
    assert_equal @user, log.actor
    assert_equal "transaction.updated", log.action
    assert_equal "10.0", log.before["amount"]
    assert_equal "42.0", log.after["amount"]
    assert_equal @entry.date, Date.parse(log.after["date"])
  end

  test "a system edit records a nil actor and a system source" do
    Current.reset

    assert_difference -> { AuditLog.count }, 1 do
      @transaction.update!(merchant: merchants(:netflix))
    end

    log = AuditLog.order(:created_at).last

    assert_nil log.actor
    assert_equal "system", log.metadata["source"]
    assert_equal merchants(:netflix).id, log.after["merchant_id"]
  end

  test "a no-op update records nothing" do
    Current.session = sessions(:one)

    assert_no_difference -> { AuditLog.count } do
      @transaction.update!(category: @transaction.category)
    end
  end

  test "records a financial change even when the record is saved again before commit" do
    Current.session = sessions(:one)

    assert_difference -> { AuditLog.count }, 1 do
      @transaction.transaction do
        @transaction.update!(category: categories(:income))
        # The controllers do this after an edit; it is a second save that would
        # otherwise wipe saved_changes before after_commit.
        @transaction.lock_attr!(:category_id)
      end
    end

    log = AuditLog.order(:created_at).last

    assert_equal categories(:food_and_drink).id, log.before["category_id"]
    assert_equal categories(:income).id, log.after["category_id"]
  end

  test "records a transfer pairing change on the transaction, not the entry" do
    Current.session = sessions(:one)

    assert_difference -> { AuditLog.count }, 1 do
      @transaction.update!(transfer_id: transfers(:one).id)
    end

    log = AuditLog.order(:created_at).last

    assert_equal "transaction.updated", log.action
    assert_equal @transaction, log.auditable
    assert_equal transfers(:one).id, log.after["transfer_id"]
    assert_includes Transaction.audited_financial_attributes, "transfer_id"
    assert_not_includes Entry.audited_financial_attributes, "transfer_id"
  end

  test "sanitizes forbidden keys at every depth" do
    log = AuditLog.record!(
      auditable: @transaction,
      action: "transaction.updated",
      metadata: {
        "source" => "web",
        "api_key" => "key",
        "nested" => {
          "raw_payload" => "payload",
          "encrypted_value" => "cipher",
          "certificate_pem" => "pem",
          "safe" => "kept"
        },
        "items" => [ { "payload" => { "value" => "x" }, "safe" => "kept" } ]
      }
    )

    assert_nil log.metadata["api_key"]
    assert_nil log.metadata["nested"]["raw_payload"]
    assert_nil log.metadata["nested"]["encrypted_value"]
    assert_nil log.metadata["nested"]["certificate_pem"]
    assert_equal "kept", log.metadata["nested"]["safe"]
    assert_nil log.metadata["items"].first["payload"]
    assert_equal "kept", log.metadata["items"].first["safe"]
  end

  test "an impersonated edit records the impersonated actor and the true user" do
    admin = users(:sure_support_staff)
    impersonation = ImpersonationSession.create!(
      impersonator: admin,
      impersonated: @user,
      status: :in_progress
    )
    admin_session = admin.sessions.create!(user_agent: "test", ip_address: "127.0.0.1")
    admin_session.update!(active_impersonator_session: impersonation)
    Current.session = admin_session

    assert_difference -> { AuditLog.count }, 1 do
      @transaction.update!(category: categories(:income))
    end

    log = AuditLog.order(:created_at).last

    assert_equal @user, log.actor
    assert_equal admin.id, log.metadata["true_user_id"]
  end

  test "a strict audit failure raises" do
    AuditLog.stubs(:create!).raises(ActiveRecord::StatementInvalid.new("audit unavailable"))

    assert_raises(ActiveRecord::StatementInvalid) do
      AuditLog.record!(auditable: @transaction, action: "transaction.updated")
    end
  end

  test "a best-effort audit failure is logged and does not raise" do
    AuditLog.stubs(:create!).raises(ActiveRecord::StatementInvalid.new("audit unavailable"))
    Rails.logger.stubs(:error)

    assert_nil AuditLog.record_best_effort!(auditable: @transaction, action: "transaction.updated")
  end

  test "a failed after-commit trail write does not fail the committed edit" do
    Current.session = sessions(:one)
    AuditLog.stubs(:create!).raises(ActiveRecord::StatementInvalid.new("audit unavailable"))
    Rails.logger.stubs(:error)

    assert @transaction.update(category: categories(:income))
    assert_equal categories(:income).id, @transaction.reload.category_id
  end

  test "purge_for_family! removes only that family's trail" do
    log = create_log
    other_family = families(:empty)
    other_category = other_family.categories.create!(name: "Other", color: "#FF0000", lucide_icon: "tag")
    other_log = AuditLog.record!(auditable: other_category, action: "transaction.updated")

    assert_difference -> { AuditLog.count }, -1 do
      AuditLog.purge_for_family!(@family)
    end

    assert_not AuditLog.exists?(log.id)
    assert AuditLog.exists?(other_log.id)
  end

  test "application code cannot rewrite audit history outside the tenant purge" do
    offenders = Dir[Rails.root.join("app/**/*.rb")].filter_map do |path|
      next if path == Rails.root.join("app/models/audit_log.rb").to_s

      source = File.read(path)
      path if source.match?(/AuditLog\b[^\n;]*\.(?:update_all|delete_all)\b/) ||
              source.match?(/audit_logs\b[^\n;]*\.(?:update_all|delete_all)\b/)
    end

    assert_empty offenders,
      "Audit history may only be purged through AuditLog.purge_for_family!: #{offenders.join(", ")}"
  end

  test "refuses updates" do
    log = create_log

    assert_raises(ActiveRecord::ReadOnlyRecord) { log.update!(action: "transaction.deleted") }
  end

  test "refuses destroy" do
    log = create_log

    assert_raises(ActiveRecord::ReadOnlyRecord) { log.destroy }
    assert AuditLog.exists?(log.id)
  end

  test "scopes entries to the audited record's family" do
    other_account = families(:empty).accounts.create!(
      name: "Other account", accountable: Depository.new, balance: 0, currency: "USD"
    )
    other_entry = other_account.entries.create!(
      name: "Other", amount: 1, currency: "USD", date: Date.current, entryable: Transaction.new
    )
    Current.session = sessions(:one)
    @transaction.update!(category: categories(:income))
    other_category = families(:empty).categories.create!(
      name: "Other", color: "#FF0000", lucide_icon: "tag"
    )
    other_entry.transaction.update!(category: other_category)

    assert_equal 1, AuditLog.for_family(@family).count
    assert_equal 1, AuditLog.for_family(families(:empty)).count
    assert_not_includes AuditLog.for_family(@family).pluck(:id), AuditLog.for_family(families(:empty)).pick(:id)
  end

  test "refuses to attach an entry to a family that does not own the audited record" do
    log = AuditLog.new(
      family: families(:empty),
      auditable: @transaction,
      action: "transaction.updated"
    )

    assert_not log.valid?
    assert log.errors[:family].any?
  end

  private
    def create_log
      AuditLog.create!(
        family: @family,
        auditable: @transaction,
        actor: @user,
        action: "transaction.updated",
        before: { "category_id" => categories(:food_and_drink).id },
        after: { "category_id" => categories(:income).id },
        request_id: "request-789",
        metadata: { "source" => "web" }
      )
    end
end
