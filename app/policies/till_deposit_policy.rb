class TillDepositPolicy < ApplicationPolicy
  def index?  = show?
  def show?   = can?(:create_shift_closing) || can?(:view_daily_reconciliation) || owner?

  # Only the holder of a depositor-type handover may record deposits.
  def create?
    can?(:create_shift_closing) &&
      record.till_handover.depositor? &&
      record.till_handover.from_user_id == user.id
  end

  def void? = can?(:verify_daily_reconciliation) || owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner? || user.can?(:view_daily_reconciliation)
        scope.joins(:till_handover)
             .where(till_handovers: { business_id: user.business_id })
      else
        scope.joins(:till_handover)
             .where(till_handovers: { business_id: user.business_id,
                                      from_user_id: user.id })
      end
    end
  end
end
