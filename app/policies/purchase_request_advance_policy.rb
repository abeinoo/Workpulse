# Advance payments to a Purchase Request's supplier. Two dedicated permissions
# (neither implied by any Purchase Request permission):
#   - manage_purchase_request_advances: record a pending advance, cancel a
#     pending one (no money has moved yet);
#   - confirm_purchase_request_advances: confirm (money moves: settlement +
#     custody debit) and reverse a confirmed one.
# Record-level state rules are enforced again, under lock, by the services.
class PurchaseRequestAdvancePolicy < ApplicationPolicy
  def create? = can?(:manage_purchase_request_advances) && same_business? &&
                (!record.is_a?(PurchaseRequestAdvance) || record.purchase_request&.receivable?)
  def new?    = create?

  def cancel?  = (can?(:manage_purchase_request_advances) || can?(:confirm_purchase_request_advances)) &&
                 same_business? && record.pending?
  def confirm? = can?(:confirm_purchase_request_advances) && same_business? && record.pending?
  def reverse? = can?(:confirm_purchase_request_advances) && same_business? && record.confirmed?
end
