class Inventory::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_inventory_access!

  private

  def require_inventory_access!
    return if current_user.can?(:view_inventory)    ||
              current_user.can?(:manage_inventory)   ||
              current_user.can?(:view_inventory_reports)

    redirect_to root_path, alert: t("flash.not_authorized")
  end

  # Active warehouses the current user may use — all of them, or only the ones
  # they're assigned to. Used to populate every warehouse dropdown.
  def accessible_warehouses
    relation = current_user.business.warehouses.active.ordered
    ids = current_user.inventory_warehouse_ids
    ids ? relation.where(id: ids) : relation
  end
  helper_method :accessible_warehouses

  # nil = all warehouses; otherwise the restricted id set.
  def accessible_warehouse_ids
    current_user.inventory_warehouse_ids
  end
  helper_method :accessible_warehouse_ids

  # Products eligible to appear in an inventory transaction line — used to
  # populate every product picker (new stock issue, import row resolution).
  def transactable_products
    current_user.business.products.transactable.ordered
  end
  helper_method :transactable_products

  # <option>s for every transactable product, built once per request (one
  # product query + one barcode query) however many pickers the page renders
  # — e.g. one per unknown-SKU import row. Rows mark their selection with
  # inventory_product_select_options.
  def transactable_product_options_html
    @transactable_product_options_html ||= begin
      products = transactable_products.to_a
      helpers.inventory_product_options_html(products, barcodes: Product.barcode_lookup(products.map(&:id)))
    end
  end
  helper_method :transactable_product_options_html

  # Refuses a write whose warehouse the scoped user isn't assigned to. Pass every
  # warehouse id the document touches (e.g. both ends of a transfer).
  def ensure_warehouses_accessible!(*warehouse_ids)
    allowed = accessible_warehouse_ids
    return if allowed.nil?

    allowed = allowed.map(&:to_s)
    given   = warehouse_ids.compact.map(&:to_s)
    raise Pundit::NotAuthorizedError if given.empty? || (given - allowed).any?
  end
end
