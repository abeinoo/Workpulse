module Inventory
  # Saves a draft (or rejected, being resubmitted) goods receipt — used by both
  # the create and update controller actions — and logs the "create"/"update"
  # audit entry. Never touches stock, custody, or settlements; that only
  # happens at confirmation (Inventory::GoodsReceiptConfirmationService).
  class GoodsReceiptDraftService
    include AuditLoggable

    Result = Struct.new(:ok, :receipt, keyword_init: true) do
      def ok? = ok
    end

    def initialize(receipt, actor:)
      @receipt = receipt
      @actor   = actor
    end

    def call
      new_record = @receipt.new_record?

      if @receipt.save
        log_audit(actor: @actor, auditable: @receipt, action: new_record ? "create" : "update")
        Result.new(ok: true, receipt: @receipt)
      else
        Result.new(ok: false, receipt: @receipt)
      end
    end
  end
end
