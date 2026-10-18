require "test_helper"

class Merchant::MergerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    Current.reset
    @family = families(:dylan_family)
    @target = merchants(:netflix)
    @source = merchants(:amazon)
  end

  teardown { Current.reset }

  test "merge! records one summary event with the affected count and actor" do
    Current.session = sessions(:one)
    Current.audit_source = "web"
    create_transaction(merchant: @source)
    create_transaction(merchant: @source)
    affected = @family.transactions.where(merchant_id: @source.id).count

    assert_difference -> { AuditLog.count }, 1 do
      Merchant::Merger.new(family: @family, target_merchant: @target, source_merchants: [ @source ]).merge!
    end

    log = AuditLog.order(:created_at).last

    assert_equal "merchant.merged", log.action
    assert_equal @family, log.family
    assert_equal @target, log.auditable
    assert_equal users(:family_admin), log.actor
    assert_equal "web", log.metadata["source"]
    assert_equal affected, log.metadata["affected_count"]
    assert_equal [ @source.id ], log.metadata["from_merchant_ids"]
    assert_equal [ @source.name ], log.metadata["from_merchant_names"]
    assert_equal @target.id, log.metadata["to_merchant_id"]
    assert_equal @target.name, log.metadata["to_merchant_name"]
  end

  # Regression: issue #1977. Merging merchants reassigns merchant_id via
  # update_all; without flagging the entries as user_modified, the next
  # provider sync reverts the merge.
  test "merge! flags reassigned transactions as user_modified" do
    entry = create_transaction(merchant: @source)
    assert_not entry.user_modified?

    Merchant::Merger.new(family: @family, target_merchant: @target, source_merchants: [ @source ]).merge!

    entry.reload
    assert_equal @target.id, entry.entryable.merchant_id, "transaction is reassigned to the target merchant"
    assert entry.user_modified?, "merged transaction's entry must be flagged so provider sync won't revert it"
  end

  test "merge! does not touch entries of unrelated merchants" do
    other = create_transaction(merchant: @target)
    assert_not other.user_modified?

    Merchant::Merger.new(family: @family, target_merchant: @target, source_merchants: [ @source ]).merge!

    other.reload
    assert_not other.user_modified?, "transactions already on the target are untouched"
  end
end
