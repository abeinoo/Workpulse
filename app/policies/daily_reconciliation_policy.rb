class DailyReconciliationPolicy < ApplicationPolicy
  def index?                 = can?(:view_daily_reconciliation)
  def verify?                = can?(:verify_daily_reconciliation)
  def assign_depositor?      = can?(:verify_daily_reconciliation)
  def create?                = can?(:create_till_session) || can?(:verify_daily_reconciliation)
  def leave_opening_float?         = can?(:close_till_session)
  def receive_opening_float?       = cashier_permission?
  def bulk_receive_opening_float?  = can?(:create_till_session) || can?(:verify_daily_reconciliation)
  def bulk_settle?                 = can?(:settle_remaining_deposit_balance)
  def export?                      = can?(:view_daily_reconciliation)
  def correct_opening_float?        = can?(:correct_opening_float)
  def update_opening_float_amounts? = can?(:correct_opening_float)
  def view_session_totals?                        = can?(:view_session_totals)
  def edit_session_totals?                        = can?(:edit_session_totals) && !record.is_a?(Class)
  def edit_day_close_amounts?                     = can?(:edit_day_close_amounts) && !record.is_a?(Class)
  def view_own_employee_reconciliation_summary?   = can?(:view_own_employee_reconciliation_summary)
  def view_all_employee_reconciliation_summary?   = can?(:view_all_employee_reconciliation_summary)
  def manage_sales_import?                          = can?(:manage_sales_import)
  def view_sales_transactions_verification?         = can?(:view_sales_transactions_verification)
  def view_pos_transaction_verification?            = can?(:view_sales_transactions_verification) && can?(:view_pos_import)

  def show?
    return true if can?(:view_daily_reconciliation)

    cashier_permission? && own_session?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      base = scope.for_business(user.business)
      return base if user.owner?

      scope_name = user.scope_for(:view_daily_reconciliation)
      return base unless scope_name

      branch_ids = BranchScope.new(user).for_scope(scope_name)
      return base.where(branch_id: branch_ids) if branch_ids.any?
      return base if scope_name == "business"

      # No managed/area branches — this is a non-manager (a plain cashier),
      # so fall back to their OWN ShiftAssignment history instead of
      # excluding them entirely. Resolved PER RECORD, against that record's
      # own business_date — never "today" — via an EXISTS correlated to the
      # same effective_from/effective_to bounds ShiftAssignment#active_on
      # uses. A DR index spans many historical business_dates at once, so a
      # single "current branch" can't answer "which of these dates were
      # mine": a temporary/date-bounded ShiftAssignment (e.g. a one-day
      # coverage assignment) that has since expired must still grant access
      # to the DR(s) on the date(s) it actually covered, at the branch it
      # actually covered — nothing more, nothing less.
      base.where(
        "EXISTS (SELECT 1 FROM shift_assignments sa " \
        "WHERE sa.user_id = :user_id AND sa.branch_id = daily_reconciliations.branch_id " \
        "AND sa.effective_from <= daily_reconciliations.business_date " \
        "AND (sa.effective_to IS NULL OR sa.effective_to >= daily_reconciliations.business_date))",
        user_id: user.id
      )
    end
  end

  private

  def cashier_permission?
    can?(:create_till_session) || can?(:close_till_session) ||
      can?(:accept_till_handover) || can?(:create_till_deposit)
  end

  def own_session?
    return true if record.waiting_for_opening? && cashier_at_branch?

    session = record.till_session
    return false unless session

    session.current_holder_id == user.id ||
      session.depositor_id == user.id ||
      record.till_handovers.pending.exists?(to_user_id: user.id)
  end

  # Uses record.business_date, not today — record here is the (possibly
  # next-day/prepared) DR being checked, and the assignment that matters is
  # whichever one covers ITS date, not necessarily today's.
  def cashier_at_branch?
    user.shift_assignments.active_on(record.business_date).exists?(branch_id: record.branch_id)
  end
end
