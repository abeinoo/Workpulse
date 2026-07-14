# manage_laundry_batches/record_batch_consumption/complete_laundry_batches
# were removed from PermissionRole::PERMISSION_GROUPS when the Laundry
# Operations permission set was simplified to match the active
# transfer-driven workflow (Towel Balances -> Transfers -> Dispatch ->
# Receipt Confirmation -> Adjustments) — see PermissionRole for the full
# rationale. They're deliberately left referenced here, unchanged: no
# PermissionRole can be granted these strings anymore (the role editor no
# longer offers them, and they're rejected on save), so these checks now
# only ever pass for the business owner (User#can? always returns true for
# owners, independent of the permission registry) — preserving direct-URL,
# owner-only access to the historical LaundryBatch workflow without deleting
# any model, controller, route, or data.
class LaundryBatchPolicy < ApplicationPolicy
  def index? = can?(:manage_laundry_batches) || can?(:view_towel_balances)
  def show?  = index? && same_business?

  # Blank form (record is the LaundryBatch class) — only the permission
  # matters, the laundry branch isn't chosen yet.
  def new? = can?(:manage_laundry_batches)

  def create? = can?(:manage_laundry_batches) && same_business? && laundry_branch_writable?
  def start?  = create?

  def record_consumption? = can?(:record_batch_consumption) && same_business? && laundry_branch_writable?

  def complete? = can?(:complete_laundry_batches) && same_business? && laundry_branch_writable?

  # Reversal undoes a completed, audited operation — same gate as completion,
  # matching how the codebase treats reversal as a natural extension of the
  # permission that produced the thing being reversed (e.g. Till Handover
  # reversal follows the same accept-adjacent permission).
  def reverse? = complete?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user.can?(:manage_laundry_batches) || user.can?(:view_towel_balances)

      base = scope.for_business(user.business)
      return base if user.owner?

      filter_by_branch_scope(base, user.scope_for(:manage_laundry_batches) || :default,
                             branch_column: :laundry_branch_id)
    end
  end

  private

  def laundry_branch_writable?
    branch_within_scope?(record.laundry_branch_id, :manage_laundry_batches, :view_towel_balances)
  end
end
