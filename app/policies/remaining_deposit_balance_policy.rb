class RemainingDepositBalancePolicy < ApplicationPolicy
  def index?        = can?(:settle_remaining_deposit_balance) || can?(:view_daily_reconciliation)
  def show?         = index?
  def bulk_settle?  = can?(:settle_remaining_deposit_balance)
  def settle?       = can?(:settle_remaining_deposit_balance) && record.open?
  def write_off?    = can?(:settle_remaining_deposit_balance) && record.open?
  def reassign?     = can?(:settle_remaining_deposit_balance) && record.open?

  class Scope < ApplicationPolicy::Scope
    def resolve
      base = scope.for_business(user.business)
      return base if user.owner?

      scope_name = user.scope_for(:settle_remaining_deposit_balance) ||
                   user.scope_for(:view_daily_reconciliation)
      return base unless scope_name

      branch_ids = BranchScope.new(user).for_scope(scope_name)
      return base if branch_ids.empty?

      base.where(branch_id: branch_ids)
    end
  end
end
