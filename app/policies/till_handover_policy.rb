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

  # Case 2: accepted, custody has NOT yet moved on from the receiver.
  # The reversal rewinds custody to the original sender via a new accounting event.
  def reverse?
    can?(:reverse_till_handover) &&
      record.accepted? &&
      !record.self_deposit? &&
      !record.reversed? &&
      !record.reversal? &&
      !record.daily_reconciliation.verified? &&
      record.daily_reconciliation.business_id == user.business_id &&
      !custody_moved_on?
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

  # Locked once custody has actually moved on from the receiver — i.e. someone
  # accepted a subsequent handover from them, or they closed the day. A still-
  # pending outgoing handover they initiated does not lock this, since custody
  # hasn't moved yet.
  def custody_moved_on?
    dr = record.daily_reconciliation
    dr.till_session.current_holder_id != record.to_user_id
  end
end
