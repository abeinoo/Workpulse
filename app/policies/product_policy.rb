class ProductPolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory) || can?(:manage_products)
  def update?  = create?
  def archive? = create?
  def restore? = create?
  def archive_family? = create?
  def destroy? = create?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
