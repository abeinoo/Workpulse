# Adjustments are append-only records — index/show/create only, never edited
# or destroyed (see TowelAdjustment / Laundry::TowelAdjuster).
class TowelAdjustmentPolicy < ApplicationPolicy
  def index? = can?(:adjust_towel_balances) || can?(:view_towel_balances)
  def show?  = index? && same_business?

  # Blank form (record is the TowelAdjustment class, or an unsaved instance
  # with no branch chosen yet) — only the permission matters.
  def new? = can?(:adjust_towel_balances)

  def create? = can?(:adjust_towel_balances) && same_business? &&
                branch_within_scope?(record.branch_id, :adjust_towel_balances, :view_towel_balances)

  private

  # Laundry staff are shift-assigned, not branch/area-managed — branch/area
  # scope must also resolve from the user's active ShiftAssignment (see
  # BranchScope).
  def branch_scope_includes_shift_assignments? = true

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user.can?(:adjust_towel_balances) || user.can?(:view_towel_balances)

      base = scope.for_business(user.business)
      return base if user.owner?

      filter_by_branch_scope(base, user.scope_for(:view_towel_balances) || :default, own_column: :created_by_id)
    end

    private

    def branch_scope_includes_shift_assignments? = true
  end
end
