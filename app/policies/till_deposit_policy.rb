class TillDepositPolicy < ApplicationPolicy
  def index? = show?
  def show?  = can?(:create_till_deposit) || can?(:view_daily_reconciliation)

  def create?
    can?(:create_till_deposit) &&
      (record.daily_reconciliation.closed? || record.daily_reconciliation.deposited?) &&
      record.daily_reconciliation.till_session&.depositor_id == user.id &&
      (record.daily_reconciliation.reviewed? || can?(:override_review_requirement))
  end

  def void?
    can?(:void_till_deposit) && !record.daily_reconciliation.verified?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.can?(:view_daily_reconciliation)
        scope.joins(:daily_reconciliation)
             .where(daily_reconciliations: { business_id: user.business_id })
      else
        scope.joins(daily_reconciliation: :till_session)
             .where(daily_reconciliations: { business_id: user.business_id })
             .where(till_sessions: { depositor_id: user.id })
      end
    end
  end
end
