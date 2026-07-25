class BankDisputePolicy < ApplicationPolicy
  def index?  = can?(:view_daily_reconciliation)

  # An accountant-tier user with view_daily_reconciliation sees any dispute
  # in scope; the employee who reported it can always view their own case
  # even without that permission (e.g. an ordinary cashier who just reported
  # an ATM problem from the Record Deposit dialog).
  def show? = index? || record.opened_by_id == user.id

  # Accountant-tier users (manage_bank_disputes) may open a dispute for any
  # deposit/reconciliation in their scope. An ordinary employee may only
  # report a problem for their own shift — the same depositor-identity check
  # TillDepositPolicy#create? already uses.
  def create?
    can?(:manage_bank_disputes) || (can?(:create_till_deposit) && own_reconciliation?)
  end

  def submit_to_bank?      = transition?("submitted_to_bank")
  def start_investigation? = transition?("under_investigation")
  def refund?               = transition?("refunded")
  def confirm_successful?   = transition?("confirmed_successful")
  def reject?                = transition?("rejected")
  def close?                  = transition?("closed")

  def update_case? = can?(:manage_bank_disputes) && record.status != "closed"

  def confirm_deposit?
    can?(:manage_bank_disputes) && record.status == "confirmed_successful" && record.till_deposit.blank?
  end

  private

  def transition?(target)
    can?(:manage_bank_disputes) && record.can_transition_to?(target)
  end

  def own_reconciliation?
    record.daily_reconciliation_for&.till_session&.depositor_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      base = scope.where(business: user.business)
      return base if user.owner?

      scope_name = user.scope_for(:manage_bank_disputes) || user.scope_for(:view_daily_reconciliation)
      return base unless scope_name

      branch_ids = BranchScope.new(user).for_scope(scope_name)
      return base if branch_ids.empty?

      base.where(branch_id: branch_ids)
    end
  end
end
