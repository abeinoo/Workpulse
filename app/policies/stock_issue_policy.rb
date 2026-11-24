# Screen-level gates for Stock Issues. The operation permissions come from
# Inventory::StockIssueAuthorization — the same rule every workflow service
# enforces itself — so a screen can never allow what its service refuses.
# Warehouse access is applied by Scope (and re-checked by every service —
# Inventory::IssueWarehouseReach); an action needs the permission AND access
# to the issue's warehouse.
class StockIssuePolicy < ApplicationPolicy
  def index?   = permits?(:view)
  def show?    = index?
  def create?  = permits?(:create)

  # Editing is allowed while a draft, and while pending approval or approved
  # ("Edit Request") — saving returns the issue to draft (see
  # Inventory::StockIssueEditor), revoking any approval and its reservation,
  # so no approval ever covers lines that changed after it. Issued (stock has
  # moved — void instead) and terminal states are never editable. `record`
  # may be the class itself for a bare permission check, so the status guard
  # only applies once we have an actual instance.
  def update?  = create? && (!record.is_a?(StockIssue) || StockIssue::EDITABLE_STATUSES.include?(record.status))

  # Deleting a draft is part of create_stock_issues (no reason, no extra
  # audit entry). Deleting and submitting stay draft-only.
  def destroy? = create? && (!record.is_a?(StockIssue) || record.draft?)
  def submit?  = destroy?

  def approve? = permits?(:approve) && (!record.is_a?(StockIssue) || record.pending_approval?)
  def reject?  = approve?

  # Physical confirmation is its own permission, separate from approval. The
  # same person may hold both and confirm what they approved.
  def confirm? = permits?(:confirm) && (!record.is_a?(StockIssue) || record.approved?)

  # Cancellation (cancel_stock_issues) is only for an issue not yet posted —
  # draft or approved, never after. Reversing a posted issue is #void?.
  def cancel?  = permits?(:cancel) && (!record.is_a?(StockIssue) || %w[draft approved].include?(record.status))

  # Void (void_stock_issues) reverses a POSTED issue only. A draft (never
  # submitted — including one still tied to an in-progress import) has no
  # movements to reverse.
  def void?    = permits?(:void) && (!record.is_a?(StockIssue) || record.issued?)

  # The Quick Issue workflow (quick_issue_stock + the business setting; the
  # owner always) — see Inventory::StockIssueQuickIssue.permitted?.
  def quick_issue? = Inventory::StockIssueQuickIssue.permitted?(user)

  # Every Stock Issue list and lookup: the user's business and the
  # warehouses they can reach (the approved warehouse-access rule; inactive
  # ones included, so their history stays visible). No branch filter: a
  # Stock Issue is authorized by its warehouse.
  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.for_business(user.business))
    end
  end

  private

  def permits?(operation) = Inventory::StockIssueAuthorization.permits?(user, operation)
end
