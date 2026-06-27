class RemainingDepositBalancePolicy < ApplicationPolicy
  def index?    = can?(:settle_remaining_deposit_balance) || can?(:view_daily_reconciliation)
  def show?     = index?
  def settle?   = can?(:settle_remaining_deposit_balance) && record.settable?
  def write_off? = can?(:settle_remaining_deposit_balance) && record.settable?
  def reassign?  = can?(:settle_remaining_deposit_balance) && record.settable?

  class Scope < ApplicationPolicy::Scope
    def resolve = scope.for_business(user.business)
  end
end
