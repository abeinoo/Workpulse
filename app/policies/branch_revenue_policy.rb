class BranchRevenuePolicy < ApplicationPolicy
  # Revenue feeds branch profitability. Report viewers see it business-wide;
  # revenue managers enter/edit it only for the branches in their configured
  # scope (manage_branch_revenue is branch-scopable: self/branch/area/business).
  def index?   = can?(:view_expense_reports) || can?(:manage_branch_revenue)
  def show?    = index? && same_business?

  # new? (blank form) only needs the permission; the branch isn't chosen yet.
  def new? = can?(:manage_branch_revenue)

  # Writes are gated on the target branch being inside the user's scope, so a
  # branch manager can't enter revenue for a branch they don't manage.
  def create?  = can?(:manage_branch_revenue) && same_business? && branch_in_write_scope?
  def update?  = create?
  def destroy? = update?

  class Scope < ApplicationPolicy::Scope
    def resolve
      base = scope.for_business(user.business)
      return base if user.owner? || user.can?(:view_expense_reports)

      if user.can?(:manage_branch_revenue)
        filter_by_branch_scope(base, user.scope_for(:manage_branch_revenue) || :default)
      else
        scope.none
      end
    end
  end

  private

  # True when the record's branch falls within the user's manage_branch_revenue
  # scope. Owners and a business-wide scope may write any branch.
  def branch_in_write_scope?
    return true if user.owner?

    scope_type = user.scope_for(:manage_branch_revenue) || :default
    return true if scope_type.to_s == "business"

    BranchScope.new(user).for_scope(scope_type).include?(record.branch_id)
  end
end
