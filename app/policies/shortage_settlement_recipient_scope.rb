# Which custody accounts a user may credit through the Daily Reconciliation
# bulk shortage settlement (Finance::BulkShortageCustodySettler) — a narrowly
# scoped authorization path for THAT operation only (owner decision 2026-11-15):
# crediting a custody account there is part of the settlement workflow, not
# general employee-balance management.
#
#   * requires settle_remaining_deposit_balance — NOT manage_employee_balances;
#   * active accounts of the user's own business, held by an active employee
#     of that business;
#   * branch scope = the scope configured on settle_remaining_deposit_balance
#     (BranchScope via filter_by_branch_scope; unset → the hierarchy default),
#     the user's own account always included; branch-less accounts therefore
#     reach only business-scoped settlers and their holder — the same shape as
#     the existing CustodyAccountPolicy rule.
#
# Grants nothing else: CustodyAccountPolicy / CustodyTransactionPolicy are not
# consulted or changed, so the Employee Balances pages, manual top-ups /
# adjustments / transfers and voids still require their own permissions.
class ShortageSettlementRecipientScope < ApplicationPolicy::Scope
  PERMISSION = :settle_remaining_deposit_balance

  def initialize(user)
    super(user, CustodyAccount)
  end

  def resolve
    return scope.none unless user.can?(PERMISSION)

    base = scope.for_business(user.business).active
                .joins(:user).where(users: { active: true, business_id: user.business_id })
    return base if user.owner?

    filter_by_branch_scope(base, user.scope_for(PERMISSION) || :default, own_column: :user_id)
  end
end
