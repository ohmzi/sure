# frozen_string_literal: true

class Ocr::Error < StandardError
  attr_reader :code

  def initialize(code, message = nil)
    @code = code
    super(message.presence || code.to_s)
  end
end
