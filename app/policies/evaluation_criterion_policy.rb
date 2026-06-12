class EvaluationCriterionPolicy < ApplicationPolicy
  def index?   = can?(:manage_evaluation_templates) || can?(:manage_settings)
  def show?    = index?
  def create?  = index?
  def update?  = index?
  def destroy? = index?

  private

  def same_business?(target = record)
    target.business_id == user.business_id
  end
end
