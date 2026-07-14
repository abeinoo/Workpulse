# Catalog is business-global (not branch-scoped) — mirrors ExpenseCategoryPolicy.
class TowelTypePolicy < ApplicationPolicy
  def index?   = can?(:view_towel_balances) || can?(:configure_towel_usage_expectations)
  def show?    = index?
  def create?  = can?(:configure_towel_usage_expectations)
  def update?  = create?
  def destroy? = create?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
