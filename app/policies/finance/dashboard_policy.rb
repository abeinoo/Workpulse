class Finance::DashboardPolicy < ApplicationPolicy
  # The finance dashboard is gated by its own dedicated permission — separate
  # from the other Finance:: permissions that Finance::BaseController accepts
  # for module entry. Having view_expenses/view_expense_reports/etc. must not
  # grant access to this page, and view_finance_dashboard must not grant
  # access to any other Finance:: page.
  def index? = can?(:view_finance_dashboard)
end
