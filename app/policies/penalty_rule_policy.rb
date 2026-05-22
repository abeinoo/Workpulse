class PenaltyRulePolicy < ApplicationPolicy
  # Branch managers can view rules on shifts they use; only super admin mutates.
  def show?    = owner? || manages_branch?
  def create?  = owner?
  def update?  = owner?
  def destroy? = owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.joins(:shift).where(shifts: { business_id: user.business_id })
    end
  end
end
