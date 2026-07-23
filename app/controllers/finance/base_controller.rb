class Finance::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_finance_access!

  private

  # Any finance permission grants entry to the module; individual actions are
  # still gated by their Pundit policies.
  FINANCE_PERMISSIONS = %i[
    view_finance_dashboard
    view_expenses create_expenses edit_expenses approve_expenses
    manage_expense_categories manage_expense_types manage_expense_tags manage_recurring_expenses
    manage_payment_methods
    view_employee_balances manage_employee_balances create_balance_requests approve_balance_requests
    view_expense_reports
    create_till_session view_daily_reconciliation view_session_totals
    close_till_session accept_till_handover create_till_deposit
    verify_daily_reconciliation edit_session_totals void_till_handover void_till_deposit
    settle_remaining_deposit_balance
    view_deposit_verification import_bank_statement verify_deposits manual_match_deposits delete_import
  ].freeze

  def require_finance_access!
    return if FINANCE_PERMISSIONS.any? { |p| current_user.can?(p) }

    redirect_to root_path, alert: t("flash.not_authorized")
  end

  def bypass_balance_account_requirement?
    current_user.owner? || current_user.can?(:manage_employee_balances)
  end
  helper_method :bypass_balance_account_requirement?

  def current_user_has_balance_account?
    CustodyAccount.exists?(business: current_user.business, user: current_user, active: true)
  end
  helper_method :current_user_has_balance_account?

  def require_balance_account!
    return if bypass_balance_account_requirement?
    return if current_user_has_balance_account?

    redirect_to finance_custody_accounts_path,
                alert: t("finance.common.no_balance_account")
  end

  # The current user's single active balance account, memoized.
  def current_user_balance_account
    @current_user_balance_account ||=
      CustodyAccount.where(business: current_user.business, user: current_user, active: true).first
  end

  # Auto-assign branch from the user's balance account when:
  #   - user is not an owner/manage_employee_balances (they use the manual dropdown)
  #   - the record doesn't already have a branch set
  #   - the balance account has a branch
  def auto_assign_branch_from_balance_account(record)
    return if bypass_balance_account_requirement?
    return if record.branch_id.present?

    account = current_user_balance_account
    return unless account&.branch_id?

    record.branch_id = account.branch_id
  end

  # Returns true when the branch selector should be hidden:
  #   - balance account exists and has a branch (branch is auto-assigned)
  def hide_branch_selector?
    return false if bypass_balance_account_requirement?

    account = current_user_balance_account
    return true unless account  # no account → hide (creation blocked separately)

    account.branch_id?  # account has branch → hide (auto-assigned); no branch → show
  end

  # Active branches the current user may attribute records to, honouring their
  # branch scope. Owners (and business-wide users) see all; others see the
  # branches they manage / area-manage. Used to populate branch dropdowns.
  def assignable_branches
    return current_user.business.branches.active.order(:name) if current_user.owner?

    ids = BranchScope.new(current_user).default_ids
    current_user.business.branches.active.where(id: ids).order(:name)
  end
  helper_method :assignable_branches

  # ── Expense-specific branch scope ─────────────────────────────────────────
  # Separate from the balance-account logic; driven by the user's permission
  # scope for create_expenses rather than their custody account.

  # "branch" / "self" → hide selector, auto-assign from shift assignment.
  # "area"            → show selector, list only the user's area branches.
  # "business" / nil  → show selector, list all branches.
  def expense_branch_scope
    return "business" if current_user.owner?
    current_user.scope_for(:create_expenses) || "branch"
  end
  helper_method :expense_branch_scope

  def hide_expense_branch_selector?
    %w[self branch].include?(expense_branch_scope)
  end

  def assignable_expense_branches
    case expense_branch_scope
    when "business"
      current_user.business.branches.active.order(:name)
    when "area"
      ids = current_user.area_managed_branch_ids
      current_user.business.branches.active.where(id: ids).order(:name)
    else
      []
    end
  end

  # Auto-set branch on an expense from the user's active shift assignment.
  # Only runs for branch-scoped users (those who won't see the selector).
  def auto_assign_expense_branch(expense)
    return unless hide_expense_branch_selector?
    return if expense.branch_id.present?

    assignment = current_user.shift_assignments.active_on(Date.current)
                             .order(effective_from: :desc).first
    expense.branch_id = assignment&.branch_id
  end
end
