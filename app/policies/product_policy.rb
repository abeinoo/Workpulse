class ProductPolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?

  # The product PICKERS (search by name / SKU / barcode, returning only the
  # picker payload — id, name, SKU, barcodes, thumbnail; no stock figures, no
  # catalogue pages): anyone who may browse the catalogue, and anyone whose
  # operation needs to pick products — Stock Issue creation and Quick Issue —
  # so those operation permissions do not have to require view_inventory.
  def pick? = index? || Inventory::StockIssueAuthorization.permits?(user, :create) ||
              Inventory::StockIssueQuickIssue.permitted?(user)
  def create?  = can?(:manage_inventory) || can?(:manage_products)
  def update?  = create?
  def archive? = create?
  def restore? = create?
  # Upload, reorder, choose the primary image of, or remove product images
  # (Inventory::ProductGalleryUpdater) — the product editors.
  def manage_images? = create?
  def destroy? = create?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
