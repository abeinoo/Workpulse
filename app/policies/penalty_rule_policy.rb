class PenaltyRulePolicy < ApplicationPolicy
  # Branch managers can view rules on shifts they use; only super admin mutates.
  def show?    = can?(:manage_shifts)
  def create?  = can?(:manage_shifts)
  def update?  = can?(:manage_shifts)
  def destroy? = can?(:manage_shifts)

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.joins(:shift).where(shifts: { business_id: user.business_id })
    end
  end
end
