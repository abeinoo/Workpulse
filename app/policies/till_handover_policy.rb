class TillHandoverPolicy < ApplicationPolicy
  # Any staff can see their own handovers; managers see their branch's.
  def index?  = can?(:create_shift_closing) || can?(:view_daily_reconciliation) || owner?
  def show?   = index?

  # Only the current till holder may submit the next handover.
  def create? = can?(:create_shift_closing)

  # Only the named recipient of a pending transfer may accept it.
  def accept?
    record.transfer? && record.pending? && record.to_user_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner? || user.can?(:view_daily_reconciliation)
        scope.for_business(user.business)
      else
        # Staff see only their own handovers.
        scope.for_business(user.business)
             .where(from_user_id: user.id)
             .or(scope.for_business(user.business).where(to_user_id: user.id))
      end
    end
  end
end
