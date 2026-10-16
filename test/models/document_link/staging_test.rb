require "test_helper"
require "tmpdir"
require "fileutils"

class DocumentLink::StagingTest < ActiveSupport::TestCase
  setup do
    @tmp = Pathname.new(Dir.mktmpdir("document-staging"))
    @link = document_links(:queued_receipt)
    @env = { "SURE_DOCUMENT_STORE_DIR" => @tmp.to_s }
  end

  teardown { FileUtils.remove_entry(@tmp) if @tmp.exist? }

  test "write stores bytes at root/<id> and stage! records the sha256" do
    with_env_overrides(@env) do
      io = StringIO.new("bank statement bytes")
      assert @link.stage!(io: io, filename: "water.pdf", content_type: "application/pdf")
      @link.reload
      assert_equal @tmp.join(@link.id).to_s, @link.stored_path
      assert_equal Digest::SHA256.hexdigest("bank statement bytes"), @link.content_sha256
      assert_equal "water.pdf", @link.original_filename
      assert_equal "application/pdf", @link.content_type
      assert File.exist?(@link.stored_path)
    end
  end

  test "stored_io yields the staged bytes or nil" do
    with_env_overrides(@env) do
      @link.stage!(io: StringIO.new("hello"), filename: "a.pdf", content_type: "application/pdf")
      @link.reload
      assert_equal "hello", @link.stored_io { |io| io.read }
      assert_nil document_links(:held_bill).stored_io { |io| io.read } # path set but file absent -> nil
    end
  end

  test "delete_stored! never moves the row's status (Ruling M3/M1 review finding 4)" do
    with_env_overrides(@env) do
      @link.stage!(io: StringIO.new("x"), filename: "a.pdf", content_type: "application/pdf")
      # Move the row to a status the old implementation would have clobbered
      # back to itself (the pre-ruling fence wrote `to: status`); update_columns
      # bypasses callbacks so the fixture row really is `linked` here.
      @link.update_columns(status: "linked")
      assert @link.reload.delete_stored!
      assert_equal "linked", @link.reload.status
      assert_nil @link.stored_path
    end
  end

  test "delete_stored! removes the file and clears stored_path" do
    with_env_overrides(@env) do
      @link.stage!(io: StringIO.new("x"), filename: "a.pdf", content_type: "application/pdf")
      @link.reload
      path = @link.stored_path
      assert @link.delete_stored!
      assert_not File.exist?(path)
      assert_nil @link.reload.stored_path
    end
  end

  test "write refuses a path outside the staging root" do
    with_env_overrides(@env) do
      assert_raises(ArgumentError) { DocumentLink::Staging.open("/etc/passwd") { |_io| } }
    end
  end

  test "write raises TooLargeError past MAX_BYTES" do
    with_env_overrides(@env) do
      big = Object.new
      def big.read(_n = nil) = @done ? nil : (@done = true; "a" * (DocumentLink::Staging::MAX_BYTES + 1))
      assert_raises(DocumentLink::Staging::TooLargeError) { DocumentLink::Staging.write(io: big, id: "x") }
    end
  end
end
