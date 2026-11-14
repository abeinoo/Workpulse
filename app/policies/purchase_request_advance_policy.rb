# Advances on a Purchase Request (funding of its responsible employee's
# custody; legacy ones were supplier payments). Two dedicated permissions
# (neither implied by any Purchase Request permission):
#   - manage_purchase_request_advances: record an advance — its funding is
#     posted immediately, there is no confirmation step — and cancel an advance
#     still pending from the old two-step workflow;
#   - confirm_purchase_request_advances (key kept for existing roles; labelled
#     "Reverse / Cancel Purchase Request Advances"): reverse a confirmed advance
#     and cancel an old pending one.
# Old pending advances are never executed — only cancelled. The responsible
# employee may not record on their own request; that and every state rule are
# enforced, under lock, by the services.
class PurchaseRequestAdvancePolicy < ApplicationPolicy
  def create? = can?(:manage_purchase_request_advances) && same_business? &&
                (!record.is_a?(PurchaseRequestAdvance) || record.purchase_request&.receivable?)
  def new?    = create?

  def cancel?  = (can?(:manage_purchase_request_advances) || can?(:confirm_purchase_request_advances)) &&
                 same_business? && record.pending?
  def reverse? = can?(:confirm_purchase_request_advances) && same_business? && record.confirmed?
end
