class CustodyTransactionPolicy < ApplicationPolicy
  def index?  = can?(:view_employee_balances) || can?(:manage_employee_balances)
  def show?   = index? && same_business?

  # Write-scoped through the account: a transaction may only be posted to a
  # custody account the user can manage (its branch / holder within scope).
  def create? = can?(:manage_employee_balances) && same_business? && account_in_scope?

  # Corrections are made by voiding (never deleting).
  def void? = can?(:manage_employee_balances) && same_business? && account_in_scope?

  # Transactions are immutable once recorded — adjust via void + new entry.
  def update?  = false
  def destroy? = false

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user.can?(:view_employee_balances) || user.can?(:manage_employee_balances)

      account_ids = CustodyAccountPolicy::Scope.new(user, CustodyAccount).resolve.select(:id)
      scope.for_business(user.business).where(custody_account_id: account_ids)
    end
  end

  private

  # The posting account must be one the user can see/manage under their custody
  # scope — reuses the account Scope so branch/holder rules stay in one place.
  def account_in_scope?
    return true if user.owner?
    return false if record.custody_account_id.nil?

    CustodyAccountPolicy::Scope.new(user, CustodyAccount).resolve.exists?(record.custody_account_id)
  end
end
