class DailyReconciliationPolicy < ApplicationPolicy
  def index?  = can?(:view_daily_reconciliation) || owner?
  def show?   = index?
  def verify? = can?(:verify_daily_reconciliation) || owner?

  # Find-or-create is gated on verify so managers can open a record.
  def create? = verify?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
