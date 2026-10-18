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
