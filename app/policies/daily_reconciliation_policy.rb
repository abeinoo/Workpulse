class DailyReconciliationPolicy < ApplicationPolicy
  def index?            = can?(:view_daily_reconciliation)
  def verify?           = can?(:verify_daily_reconciliation)
  def assign_depositor? = can?(:verify_daily_reconciliation)
  def create?           = can?(:create_till_session) || can?(:verify_daily_reconciliation)

  def show?
    return true if can?(:view_daily_reconciliation)

    cashier_permission? && own_session?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      base = scope.for_business(user.business)
      return base if user.owner?

      scope_name = user.scope_for(:view_daily_reconciliation)
      return base unless scope_name

      branch_ids = BranchScope.new(user).for_scope(scope_name)

      if branch_ids.empty? && scope_name != "business"
        branch_ids = user.shift_assignments.current.pluck(:branch_id).uniq
      end

      return base if branch_ids.empty?

      base.where(branch_id: branch_ids)
    end
  end

  private

  def cashier_permission?
    can?(:create_till_session) || can?(:close_till_session) ||
      can?(:accept_till_handover) || can?(:create_till_deposit)
  end

  def own_session?
    session = record.till_session
    return false unless session

    session.current_holder_id == user.id ||
      session.depositor_id == user.id ||
      record.till_handovers.pending.exists?(to_user_id: user.id)
  end
end
