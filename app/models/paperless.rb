module Paperless
  TOKEN_INVALID_KEY = "paperless_token_invalid_at".freeze

  # Get-or-create a tag by name and return its PK. Paperless resolves upload
  # `tags` by PK, so names must be resolved before post_document.
  def self.tag_id(name)
    client.tag_id(name)
  end

  def self.client
    Client.new
  end

  # A 401 was seen on the last attempt. Stored as an ISO8601 string so the value
  # round-trips without depending on settings-value typing.
  def self.note_token_invalid!
    Setting[TOKEN_INVALID_KEY] = Time.current.iso8601
  end

  def self.clear_token_invalid!
    Setting[TOKEN_INVALID_KEY] = nil
  end

  def self.token_invalid_at
    value = Setting[TOKEN_INVALID_KEY]
    Time.zone.parse(value) if value.present?
  end
end
