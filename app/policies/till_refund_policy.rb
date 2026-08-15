class TillRefundPolicy < ApplicationPolicy
  # Refunds are independent of TillHandover/close_till_session — a distinct,
  # explicitly-granted authority (Super Admin, Area Manager within their
  # BranchScope, or anyone else holding process_till_refund), not an implicit
  # extension of the cashier-level close_till_session permission.
  def create?
    can?(:process_till_refund) &&
      record.daily_reconciliation.open? &&
      branch_within_scope?(record.daily_reconciliation.branch_id, :process_till_refund)
  end

  def index? = can?(:process_till_refund) || can?(:view_daily_reconciliation)
  def show?  = index?
end
