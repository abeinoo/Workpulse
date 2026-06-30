class FinancialAdjustmentPolicy < ApplicationPolicy
  # Adjustments are shown wherever their adjustable record is shown.
  # Creation is always gated through the specific financial object's policy
  # (e.g. TillHandoverPolicy#adjust?), never through this policy directly.
  def show?  = can?(:view_daily_reconciliation)
  def index? = can?(:view_daily_reconciliation)
end
