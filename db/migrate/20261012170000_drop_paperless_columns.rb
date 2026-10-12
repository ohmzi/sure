class DropPaperlessColumns < ActiveRecord::Migration[8.1]
  def change
    # Safe here and only here: this is the commit in which the last reader of
    # these columns is deleted. Never move this migration earlier.
    remove_column :document_links, :paperless_document_id, :bigint
    remove_column :document_links, :paperless_task_id, :string
    remove_column :document_links, :poll_attempts, :integer
  end
end
