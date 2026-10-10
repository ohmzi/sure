class Paperless::Error < StandardError
  CODES = %i[unreachable unauthorized task_failed not_found bad_response].freeze

  attr_reader :code

  def initialize(message = nil, code: :bad_response)
    super(message)
    @code = code
  end
end
