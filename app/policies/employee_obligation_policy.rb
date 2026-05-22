class EmployeeObligationPolicy < ApplicationPolicy
  def index?  = owner? || can?(:manage_obligations) || managing?
  def show?   = owner? || can?(:manage_obligations) || manages_their_branch?
  def create? = owner? || can?(:manage_obligations)
  def update? = owner? || can?(:manage_obligations)
  def pause?  = owner? || can?(:manage_obligations)
  def resume? = owner? || can?(:manage_obligations)
  def cancel? = owner? || can?(:manage_obligations)

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner? || user.can?(:manage_obligations)
        scope.for_business(user.business)
      elsif user.manages_branch?
        employee_ids = User.where(id: user.managed_branch_ids.flat_map { |bid|
          UserBranch.where(branch_id: bid).pluck(:user_id)
        }).pluck(:id)
        scope.for_business(user.business).where(user_id: [user.id] + employee_ids)
      else
        scope.none
      end
    end
  end

  private

  def manages_their_branch?
    return false unless manages_branch?
    employee_branch_ids = UserBranch.where(user_id: record.user_id).pluck(:branch_id)
    (user.managed_branch_ids & employee_branch_ids).any?
  end
end
