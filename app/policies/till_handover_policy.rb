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

  def leave_opening_float? = can?(:close_till_session)

  def accept?
    can?(:accept_till_handover) &&
      record.pending? &&
      record.to_user_id == user.id
  end

  def cancel?
    can?(:void_till_handover) &&
      record.pending? &&
      !record.daily_reconciliation.verified? &&
      record.daily_reconciliation.business_id == user.business_id
  end

  # Case 2: accepted, receiver has NOT yet started working on this DR.
  # The reversal rewinds custody to the original sender via a new accounting event.
  def reverse?
    can?(:reverse_till_handover) &&
      record.accepted? &&
      !record.self_deposit? &&
      !record.reversed? &&
      !record.reversal? &&
      !record.daily_reconciliation.verified? &&
      record.daily_reconciliation.business_id == user.business_id &&
      !receiver_started_working?
  end

  # Case 3: accepted, receiver IS working (or manager chooses documentary correction).
  # Creates an immutable FinancialAdjustment; the original record is never changed.
  def adjust?
    can?(:adjust_till_handover) &&
      record.accepted? &&
      !record.self_deposit? &&
      !record.daily_reconciliation.verified? &&
      record.daily_reconciliation.business_id == user.business_id
  end

  private

  def receiver_started_working?
    dr = record.daily_reconciliation
    dr.till_handovers
      .where(from_user_id: record.to_user_id)
      .where.not(id: record.id)
      .exists?
  end
end
