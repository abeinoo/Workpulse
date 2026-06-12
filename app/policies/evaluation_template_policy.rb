class EvaluationTemplatePolicy < ApplicationPolicy
  def index?   = can?(:manage_evaluation_templates) || can?(:manage_settings)
  def show?    = index?
  def create?  = index?
  def update?  = index?
  def destroy? = index?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
