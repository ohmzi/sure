require "test_helper"

class AuditLogsHelperTest < ActionView::TestCase
  include AuditLogsHelper

  test "a statement delete event renders the filename stored on the event" do
    log = AuditLog.new(
      action: "account_statement.deleted",
      before: { "filename" => "statement.pdf" },
      metadata: { "source" => "web" }
    )

    assert_equal "Statement: statement.pdf", audit_event_detail(log)
  end
end
