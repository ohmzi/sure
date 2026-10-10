Paperless::Task = Data.define(:status, :document_id, :duplicate_of, :error_message) do
  def success? = status == :success
  def failure? = status == :failure
end
