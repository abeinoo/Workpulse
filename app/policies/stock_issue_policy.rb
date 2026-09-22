class StockIssuePolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory) || can?(:manage_stock_issues)

  # Editing (and submitting) is only meaningful while still a draft — once
  # submitted, the issue is waiting on an approver and must not change under
  # them. `record` may be the class itself for a bare permission check, so the
  # draft guard only applies once we have an actual instance.
  def update?  = create? && (!record.is_a?(StockIssue) || record.draft?)
  def destroy? = update?
  def submit?  = update?

  def approve? = (can?(:manage_inventory) || can?(:approve_stock_issues)) &&
                 (!record.is_a?(StockIssue) || record.pending_approval?)
  def reject?  = approve?

  # Physical confirmation is its own permission, separate from approval — the
  # person who approves an issue is not automatically the person trusted to
  # confirm it was physically handed over.
  def confirm? = (can?(:manage_inventory) || can?(:confirm_stock_issues)) &&
                 (!record.is_a?(StockIssue) || record.approved?)

  # Cancellation is only safe before anything is physically issued — draft or
  # approved, never after (that's #void?'s job, since it reverses real posted
  # movements). Same permission as create/edit, mirroring GoodsReceiptPolicy's
  # #cancel?.
  def cancel?  = create? && (!record.is_a?(StockIssue) || %w[draft approved].include?(record.status))

  # A draft (never submitted — including one still tied to an in-progress
  # import) has no movements to reverse — voiding it would fabricate a
  # compensating "return" for stock that was never actually taken out. Only
  # an "issued" record has posted movements.
  def void?
    return false unless create?
    record.is_a?(StockIssue) ? record.issued? : true
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.for_business(user.business))
    end
  end
end
