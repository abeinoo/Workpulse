module Inventory
  # Read-only: what approving a pending, employee-custody-funded goods receipt
  # will take from that custody account — shown to the approver BEFORE they
  # approve (the receipt's page, and the approve dialog on the Goods Receipts
  # list / Purchase Request page). Records nothing; the actual payment happens
  # only in Inventory::GoodsReceiptApproval#approve!, which applies the same
  # amount due (PurchaseRequestAdvanceAllocator).
  #
  # Returns nil when not applicable, { account: nil } when the receipt has no
  # active custody account, else { account:, current:, due:, after: }.
  class CustodyPaymentPreview
    def self.for(receipt, allocator: nil)
      return unless receipt.approval_pending_approval? && receipt.employee_custody_funded?

      account = receipt.funding_source
      return { account: nil } unless account.is_a?(CustodyAccount) && account.active?

      current = account.computed_balance
      due     = (allocator || PurchaseRequestAdvanceAllocator.new(receipt)).amount_due
      { account: account, current: current, due: due, after: current - due }
    end
  end
end
