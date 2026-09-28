module Inventory
  # Saves a draft (or rejected, being resubmitted) goods receipt — used by both
  # the create and update controller actions — and logs the "create"/"update"
  # audit entry. Never touches stock, custody, or settlements; that only
  # happens at confirmation (Inventory::GoodsReceiptConfirmationService).
  #
  # Also the single place a receipt's funding_source is resolved: Employee
  # Custody always means the ACTOR's own active custody account in this
  # business — never an account chosen or submitted by the browser. An actor
  # with none leaves funding_source nil, which GoodsReceipt's validation
  # reports as "you do not have a custody account". Every other kind carries
  # no funding_source (cleared, so switching a draft away from custody works).
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
      assign_funding_source

      if @receipt.save
        log_audit(actor: @actor, auditable: @receipt, action: new_record ? "create" : "update")
        Result.new(ok: true, receipt: @receipt)
      else
        Result.new(ok: false, receipt: @receipt)
      end
    end

    private

    def assign_funding_source
      @receipt.funding_source = (@actor.custody_accounts.active.find_by(business_id: @receipt.business_id) if @receipt.employee_custody_funded?)
    end
  end
end
