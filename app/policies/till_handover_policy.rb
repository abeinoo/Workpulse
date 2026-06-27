class TillHandoverPolicy < ApplicationPolicy
  def my_shift?
    can?(:create_till_session) || can?(:close_till_session) || can?(:accept_till_handover) || can?(:create_till_deposit)
  end

  def index?
    can?(:close_till_session) || can?(:accept_till_handover) || can?(:view_daily_reconciliation)
  end

  def show? = index?

  def create?
    can?(:close_till_session)
  end

  def accept?
    can?(:accept_till_handover) &&
      record.pending? &&
      record.to_user_id == user.id
  end
end
