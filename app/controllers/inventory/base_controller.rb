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

  # (Product pickers search on demand — Inventory::ProductPickerSearch — so no
  # page builds the whole catalogue as <option>s any more.)

  # Refuses a write whose warehouse the scoped user isn't assigned to. Pass every
  # warehouse id the document touches (e.g. both ends of a transfer).
  def ensure_warehouses_accessible!(*warehouse_ids)
    allowed = accessible_warehouse_ids
    return if allowed.nil?

    allowed = allowed.map(&:to_s)
    given   = warehouse_ids.compact.map(&:to_s)
    raise Pundit::NotAuthorizedError if given.empty? || (given - allowed).any?
  end

  # Product thumbnails (ProductThumbnailHelper) read only preloaded images:
  # preload them for exactly the products a page is about to list — three
  # queries, whatever the count (images, attachments, blobs). Report services stay untouched.
  def preload_product_images(products)
    # By object, not id: the same product may come as separate objects from
    # different reports, and each one must be marked loaded.
    records = Array(products).compact.uniq(&:object_id)
    ActiveRecord::Associations::Preloader.new(records: records, associations: Product::IMAGE_PRELOAD).call if records.any?
    products
  end

  # Document forms with searchable product pickers render only each line's
  # SELECTED product (the catalogue is searched on demand): load those with
  # their barcodes and images in one go — never one query per line.
  def preload_line_products(lines)
    records = Array(lines).select(&:product_id)
    return if records.empty?

    ActiveRecord::Associations::Preloader.new(
      records: records, associations: { product: [ :product_barcodes, :active_packaging_levels, Product::IMAGE_PRELOAD ] }
    ).call
  end

  # A posted document's packaging entries for its show page (one query; none
  # for documents of products without packaging).
  def packaging_entries_of(document)
    InventoryPackagingEntry.where(source: document).includes(:packaging_level, :warehouse, :product).order(:id).to_a
  end

  # The one product payload of the searchable product pickers and the barcode
  # scanner (product-combobox / lib/product_option.js): everything a line's
  # existing listeners read from the product's <option>. Images / barcodes
  # should be preloaded by the caller.
  def product_picker_json(product)
    barcodes = product.product_barcodes.map(&:barcode)
    { id: product.id, name: product.name, sku: product.sku, barcode: product.barcode, barcodes: barcodes,
      default_supplier_id: product.default_supplier_id, measure: helpers.measure_short(product),
      thumb: helpers.product_thumbnail_url(product, preloaded_only: true),
      units: helpers.packaging_units(product) }
  end

  # Eligible Purchase Request responsible employees (purchasing permission +
  # active custody account) for the request form, the Low Stock review modal
  # and the assign action — decided by Finance & Sales.
  def load_responsible_options
    @responsible_options = Inventory::PurchaseRequestAdvanceEffects.responsible_employee_options(actor: current_user)
  end
end
