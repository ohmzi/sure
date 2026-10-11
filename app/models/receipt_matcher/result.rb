class ReceiptMatcher::Result
  STATUSES = %i[suggested pending_review no_match].freeze

  attr_reader :status, :candidates

  def initialize(status:, candidates: [])
    raise ArgumentError, "unknown status #{status}" unless STATUSES.include?(status)

    @status = status
    @candidates = candidates
  end

  def suggested?;       status == :suggested; end
  def pending_review?;  status == :pending_review; end
  def no_match?;        status == :no_match; end

  def best
    candidates.first
  end
end
