class TillDepositPolicy < ApplicationPolicy
  def index? = show?
  def show?  = can?(:create_till_deposit) || can?(:view_daily_reconciliation)

  def create?
    (record.daily_reconciliation.closed? || record.daily_reconciliation.deposited?) &&
      # Super Admin (business owner) is never blocked by depositor assignment.
      (owner? || (can?(:create_till_deposit) &&
        record.daily_reconciliation.till_session&.depositor_id == user.id))
  end

  def void?
    can?(:void_till_deposit) && !record.daily_reconciliation.verified?
  end

  # Manually attach an unmatched BankStatementTransaction to this deposit —
  # the deposit-side mirror of BankStatementTransactionPolicy#match?.
  def match? = can?(:manual_match_deposits) && same_business?

  # Mark this deposit as ignored (excluded from "Missing from Bank"), or
  # reverse that — same permission gates both directions, mirroring how
  # BankStatements::Ignorer/Unmatcher share no separate policy split either.
  def ignore?   = can?(:ignore_deposits) && same_business?
  def unignore? = ignore?

  private

  def same_business?
    record.daily_reconciliation.business_id == user.business_id
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
