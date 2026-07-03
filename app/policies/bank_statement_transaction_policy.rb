class BankStatementTransactionPolicy < ApplicationPolicy
  def show?    = can?(:view_deposit_verification) && same_business?
  def match?   = can?(:manual_match_deposits) && same_business?
  def unmatch? = can?(:manual_match_deposits) && same_business?
  def ignore?  = can?(:manual_match_deposits) && same_business?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user.can?(:view_deposit_verification)

      base = scope.for_business(user.business)
      return base if user.owner?

      scope_type = user.scope_for(:view_deposit_verification) || :default
      return base if scope_type.to_s == "business"

      # Transactions inherit branch visibility from their parent statement.
      # Business-wide statements (branch_id: nil) are visible to all branch-
      # scoped users; branch-specific statements are filtered by scope.
      branch_ids = BranchScope.new(user).for_scope(scope_type)
      base.joins(:bank_statement).where(bank_statements: { branch_id: [ nil, *branch_ids ] })
    end
  end

  private

  def same_business?
    record.respond_to?(:business_id) && record.business_id == user.business_id
  end
end
