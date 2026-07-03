class BankStatementPolicy < ApplicationPolicy
  def index?   = can?(:view_deposit_verification)
  def show?    = can?(:view_deposit_verification) && same_business?
  def new?     = can?(:import_bank_statement)
  def create?  = can?(:import_bank_statement)
  def destroy? = can?(:delete_import) && same_business?

  def edit_column_mapping?   = can?(:import_bank_statement) && same_business?
  def update_column_mapping? = can?(:import_bank_statement) && same_business?
  def rematch?               = can?(:import_bank_statement) && same_business?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user.can?(:view_deposit_verification)

      base = scope.for_business(user.business).active
      return base if user.owner?

      scope_type = user.scope_for(:view_deposit_verification) || :default
      return base if scope_type.to_s == "business"

      filter_by_branch_scope(base, scope_type)
    end
  end
end
