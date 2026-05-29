class ShiftTemplatePolicy < ApplicationPolicy
  def index?         = can?(:assign_shifts) || can?(:view_shifts)
  def show?          = can?(:assign_shifts) || can?(:view_shifts)
  def create?        = can?(:assign_shifts)
  def update?        = can?(:assign_shifts)
  def archive?       = can?(:assign_shifts)
  def unarchive?     = can?(:assign_shifts)
  def apply?         = can?(:assign_shifts)
  def preview_apply? = can?(:assign_shifts)

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
