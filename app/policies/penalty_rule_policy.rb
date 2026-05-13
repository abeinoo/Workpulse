class PenaltyRulePolicy < ApplicationPolicy
  # Branch managers can view rules on shifts they use; only super admin mutates.
  def show?    = super_admin? || branch_manager?
  def create?  = super_admin?
  def update?  = super_admin?
  def destroy? = super_admin?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.joins(:shift).where(shifts: { business_id: user.business_id })
    end
  end
end
