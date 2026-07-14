class TowelTransferPolicy < ApplicationPolicy
  def index? = can?(:view_towel_balances)
  def show?  = can?(:view_towel_balances) && same_business?

  # Blank form (record is the TowelTransfer class, e.g. a "new transfer" link
  # in a nav/dashboard) — only the permission matters, no branch is chosen yet.
  def new? = can?(:create_towel_transfers)

  def create? = can?(:create_towel_transfers) && same_business? &&
                branch_within_scope?(record.source_branch_id, :create_towel_transfers, :view_towel_balances)

  # Status is part of authorization, not just view-hiding — a draft can be
  # dispatched, a dispatched transfer can be received, either can be
  # cancelled; nothing else is ever true. The service layer re-checks this
  # again under a row lock (see Laundry::TowelTransferCreator), so this is
  # defense in depth against a stale page / direct request, not the only guard.
  def dispatch? = record.draft? && can?(:create_towel_transfers) && same_business? &&
                  branch_within_scope?(record.source_branch_id, :create_towel_transfers, :view_towel_balances)

  def receive? = record.dispatched? && can?(:confirm_towel_receipt) && same_business? &&
                 branch_within_scope?(record.destination_branch_id, :confirm_towel_receipt, :view_towel_balances)

  # Either side may cancel while the transfer hasn't been received yet.
  def cancel? = (record.draft? || record.dispatched?) && can?(:create_towel_transfers) && same_business? &&
                (branch_within_scope?(record.source_branch_id, :create_towel_transfers, :view_towel_balances) ||
                 branch_within_scope?(record.destination_branch_id, :confirm_towel_receipt, :view_towel_balances))

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user.can?(:view_towel_balances)

      base = scope.for_business(user.business)
      return base if user.owner?

      scope_type = user.scope_for(:view_towel_balances) || :default
      return base if scope_type.to_s == "business"

      branch_ids = BranchScope.new(user).for_scope(scope_type)
      base.where(source_branch_id: branch_ids).or(base.where(destination_branch_id: branch_ids))
    end
  end
end
