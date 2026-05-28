class ShiftTemplatePolicy < ApplicationPolicy
  def index?         = owner? || can?(:assign_shifts) || can?(:view_shifts) || manages_branch? || manages_area?
  def show?          = owner? || can?(:assign_shifts) || can?(:view_shifts) || manages_branch? || manages_area?
  def create?        = owner? || can?(:assign_shifts) || manages_branch? || manages_area?
  def update?        = owner? || can?(:assign_shifts) || manages_branch? || manages_area?
  def archive?       = owner? || can?(:assign_shifts) || manages_branch? || manages_area?
  def unarchive?     = owner? || can?(:assign_shifts) || manages_branch? || manages_area?
  def apply?         = owner? || can?(:assign_shifts) || manages_branch? || manages_area?
  def preview_apply? = owner? || can?(:assign_shifts) || manages_branch? || manages_area?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
