class DepositResponsibilityTransferPolicy < ApplicationPolicy
  # The target recipient, the assigning user, and anyone who can view the DR
  # may inspect the transfer.
  def show?
    record.to_user == user || record.from_user == user || user.can?(:view_daily_reconciliation)
  end

  # Only the named recipient may accept, and only while the transfer is still
  # pending. Super Admin (business owner) is never blocked by recipient
  # assignment.
  def accept?
    record.pending? && (owner? || record.to_user == user)
  end

  # The assigning user (from_user) or a manager may cancel while still pending.
  # Accepted transfers are immutable.
  def cancel?
    record.pending? && (record.from_user == user || user.can?(:view_daily_reconciliation))
  end
end
