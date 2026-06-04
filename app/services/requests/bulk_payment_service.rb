module Requests
  # Marks a set of approved salary-advance requests as paid in one transaction.
  #
  # The caller is responsible for authorization and for scoping `requests` to the
  # acting user's business (e.g. via policy_scope). This service:
  #
  #   1. Partitions the given requests into payable vs. skipped (already paid,
  #      rejected, pending, non-advance, …) — skipped requests are reported, never
  #      processed.
  #   2. Pays every payable request inside a single DB transaction, stamping each
  #      Advance with the chosen `paid_at` timestamp and the optional note.
  #   3. Writes ONE summary AuditLog entry recording the actor, request count,
  #      total amount, and paid_at — in addition to the per-request "pay" entries
  #      written by Requests::Approver.
  #
  # Partial failure is a first-class outcome: valid requests are paid even when
  # the selection also contains invalid ones.
  class BulkPaymentService
    include AuditLoggable

    Skipped = Struct.new(:request, :reason, keyword_init: true)

    Result = Struct.new(:paid, :skipped, :paid_at, :total_amount, keyword_init: true) do
      def paid_count    = paid.size
      def skipped_count = skipped.size
      def any_paid?     = paid.any?
    end

    def self.call(requests:, paid_by:, paid_at: nil, notes: nil)
      new(requests: requests, paid_by: paid_by, paid_at: paid_at, notes: notes).call
    end

    def initialize(requests:, paid_by:, paid_at: nil, notes: nil)
      @requests = Array(requests)
      @paid_by  = paid_by
      @paid_at  = resolve_paid_at(paid_at)
      @notes    = notes.presence
    end

    def call
      payable, skipped = partition

      paid = []
      if payable.any?
        ActiveRecord::Base.transaction do
          payable.each do |request|
            result = Requests::Approver.pay(
              request: request, paid_by: @paid_by, paid_at: @paid_at, note: @notes
            )
            if result.success?
              paid << request
            else
              # Defensive: a request that passed the upfront filter but failed at
              # pay-time (e.g. a race) is reported rather than aborting the batch.
              skipped << Skipped.new(request: request, reason: result.error)
            end
          end
        end
      end

      total = paid.sum { |r| r.amount.to_f }
      log_bulk(paid: paid, total: total) if paid.any?

      Result.new(paid: paid, skipped: skipped, paid_at: @paid_at, total_amount: total)
    end

    private

    # Splits @requests into [payable, skipped]. A request is payable only when it
    # is an approved salary advance that has not already been disbursed.
    def partition
      payable = []
      skipped = []

      @requests.each do |request|
        if skip_reason(request)
          skipped << Skipped.new(request: request, reason: skip_reason(request))
        else
          payable << request
        end
      end

      [payable, skipped]
    end

    def skip_reason(request)
      return :not_advance unless request.salary_advance?
      return :already_paid if request.paid? || request.advance.present?
      return :rejected     if request.rejected?
      return :not_approved unless request.approved?

      nil
    end

    def log_bulk(paid:, total:)
      log_audit(
        actor:     @paid_by,
        auditable: @paid_by,
        action:    "bulk_pay_advances",
        metadata:  {
          request_count: paid.size,
          request_ids:   paid.map(&:id),
          total_amount:  total,
          paid_at:       @paid_at,
          note:          @notes
        }.compact
      )
    end

    def resolve_paid_at(value)
      return Time.current if value.blank?

      Time.zone.parse(value.to_s) || Time.current
    rescue ArgumentError
      Time.current
    end
  end
end
