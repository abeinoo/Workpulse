class BankStatementTransactionPolicy < ApplicationPolicy
  def show?    = can?(:view_deposit_verification) && same_business?
  # A line of a soft-deleted statement is kept for audit history only: it can
  # no longer be matched or ignored. Unmatch stays available so a link left
  # on it (before deletion released matches) can still be removed.
  def match?   = can?(:manual_match_deposits) && same_business? && active_statement?
  def unmatch? = can?(:manual_match_deposits) && same_business?
  def ignore?  = can?(:manual_match_deposits) && same_business? && active_statement?

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

  def active_statement?
    !record.bank_statement.deleted?
  end

  def same_business?
    record.respond_to?(:business_id) && record.business_id == user.business_id
  end
end
