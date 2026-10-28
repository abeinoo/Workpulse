module Inventory
  # One-off normalization for goods receipts voided BEFORE GoodsReceiptVoider
  # moved an undecided approval to "cancelled": voided (voided_at set) yet still
  # approval_status draft / pending_approval — shown as "awaiting approval"
  # next to a "voided" receiving status, and counted in the pending-approval KPI.
  #
  # Applies exactly the transition the voider now performs (approval_status →
  # cancelled), nothing else: voided_at, stock movements, settlements and the
  # original void audit entry are untouched. Each change appends its own audit
  # row. Approved/rejected decisions are history and never touched.
  #
  # Dry run by default — call with apply: true to write. Idempotent.
  class GoodsReceiptCancelledApprovalNormalizer
    include AuditLoggable

    Result = Struct.new(:candidates, :updated, :failed, keyword_init: true)

    def self.candidates(business_id: nil)
      scope = GoodsReceipt.voided.where(approval_status: GoodsReceipt::UNDECIDED_APPROVAL_STATUSES)
      scope = scope.where(business_id: business_id) if business_id
      scope.order(:id)
    end

    def initialize(apply: false, business_id: nil, actor: nil)
      @apply       = apply
      @business_id = business_id
      @actor       = actor
    end

    def call
      receipts = self.class.candidates(business_id: @business_id).to_a
      updated  = []
      failed   = []

      if @apply
        receipts.each do |receipt|
          normalize!(receipt)
          updated << receipt
        rescue => e
          failed << [ receipt, e.message ]
        end
      end

      Result.new(candidates: receipts, updated: updated, failed: failed)
    end

    private

    def normalize!(receipt)
      ActiveRecord::Base.transaction do
        receipt.lock!
        from = receipt.approval_status
        return unless receipt.voided? && GoodsReceipt::UNDECIDED_APPROVAL_STATUSES.include?(from)

        # update_columns: a historical receipt may no longer satisfy validations
        # added after it was voided (e.g. invoices); only the approval status moves.
        receipt.update_columns(approval_status: "cancelled", updated_at: Time.current)
        # Fail-closed (BUG-003): this entry is the repair's only evidence and
        # the only record of the previous approval status; #call reports the
        # receipt as failed and leaves it unchanged.
        log_audit!(actor: @actor || receipt.voided_by || receipt.business.owner, auditable: receipt, action: "normalize_cancelled_approval",
                   changes: { approval_status: [ from, "cancelled" ] },
                   metadata: { reason: "voided receipt left in an undecided approval state",
                               voided_at: receipt.voided_at&.iso8601 })
      end
    end
  end
end
