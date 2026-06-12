class DepartmentPolicy < ApplicationPolicy
  # Departments are managed alongside business settings / evaluation templates.
  def index?   = can?(:manage_evaluation_templates) || can?(:manage_settings)
  def show?    = index?
  def create?  = index?
  def update?  = index?
  # Soft-delete (deactivate) is the supported lifecycle; hard destroy is blocked
  # by the model when dependents exist.
  def destroy? = index?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
