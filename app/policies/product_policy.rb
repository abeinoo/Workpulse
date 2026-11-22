class ProductPolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory) || can?(:manage_products)
  def update?  = create?
  def archive? = create?
  def restore? = create?
  # Upload, reorder, choose the primary image of, or remove product images
  # (Inventory::ProductGalleryUpdater) — the product editors.
  def manage_images? = create?
  # Define / change the product's packaging levels (Inventory::Packaging::Configurator).
  def configure_packaging? = create?
  def destroy? = create?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
