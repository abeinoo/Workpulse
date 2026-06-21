class Product < ApplicationRecord
  include Attachable

  has_one_attached :image

  validates_attachment :image,
    content_types: Attachable::IMAGE_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_MAX_SIZE

  belongs_to :business
  belongs_to :brand,            optional: true
  belongs_to :product_category, optional: true
  belongs_to :default_supplier, class_name: "Supplier", optional: true
  belongs_to :parent_product,   class_name: "Product", optional: true,
                                foreign_key: :parent_product_id, inverse_of: :child_products

  has_many :child_products, class_name: "Product", foreign_key: :parent_product_id,
                            inverse_of: :parent_product, dependent: :nullify
  has_many :goods_receipt_items,   dependent: :restrict_with_error
  has_many :stock_issue_items,     dependent: :restrict_with_error
  has_many :stock_transfer_items,  dependent: :restrict_with_error
  has_many :stock_adjustment_items, dependent: :restrict_with_error
  has_many :stock_count_items,     dependent: :restrict_with_error
  has_many :inventory_movements,   dependent: :restrict_with_error
  has_many :product_warehouse_settings, dependent: :destroy
  has_many :configured_warehouses, through: :product_warehouse_settings, source: :warehouse
  has_many :product_barcodes,   dependent: :destroy

  accepts_nested_attributes_for :product_warehouse_settings,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:warehouse_id].blank? }
  accepts_nested_attributes_for :product_barcodes,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:barcode].blank? }

  validates :name, presence: true, length: { maximum: 200 }
  validates :sku,  presence: true, length: { maximum: 80 }
  validates :sku,  uniqueness: { scope: :business_id, case_sensitive: false }
  validates :initial_cost_price, :average_cost_price,
            numericality: { greater_than_or_equal_to: 0 }
  validates :last_purchase_price,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :low_stock_level, :reorder_quantity,
            numericality: { greater_than_or_equal_to: 0 }
  validates :selling_markup_percentage,
            numericality: { greater_than_or_equal_to: 0 }
  validate :parent_depth_constraint, if: :parent_product_id?
  validate :not_own_parent,          if: :parent_product_id?

  # Parent must not itself be a child — enforces max depth = 1.
  def parent_depth_constraint
    return unless parent_product
    if parent_product.parent_product_id?
      errors.add(:parent_product_id, :too_deep)
    end
  end

  def not_own_parent
    errors.add(:parent_product_id, :circular) if parent_product_id == id
  end

  # Force parent products to non-tracking before every save.
  # Runs AFTER validations so the attribute is always correct at the DB layer
  # regardless of what was submitted through the form.
  before_save :enforce_parent_not_tracked
  before_save :ensure_single_primary_barcode

  # When this product gains a parent, that parent must be forced non-tracking.
  # Uses update! (not update_columns) so callbacks, dirty tracking and any future
  # audit trail (e.g. PaperTrail) all fire on the parent record.
  after_save  :propagate_non_tracking_to_parent, if: :saved_change_to_parent_product_id?
  # Auto-generate a primary barcode when the product is created with no barcodes.
  # Fires after nested product_barcodes are already saved, so the check is accurate.
  after_create :auto_generate_barcode

  scope :for_business,       ->(business) { where(business: business) }
  scope :ordered,            -> { order(:name) }
  scope :active,             -> { where(active: true) }
  scope :archived,           -> { where(active: false) }
  scope :inventory_tracked,  -> { where(track_inventory: true) }
  scope :low_stock_notifiable, -> { inventory_tracked.where(receive_low_stock_notification: true) }
  # Exclude products that have children — parents carry no inventory of their own.
  scope :non_parent, -> {
    where("NOT EXISTS (SELECT 1 FROM products c WHERE c.parent_product_id = products.id)")
  }
  # Only products that may appear in inventory transaction line items:
  # active standalone/child products, never parent or archived products.
  scope :transactable, -> {
    where(active: true)
      .where("NOT EXISTS (SELECT 1 FROM products c WHERE c.parent_product_id = products.id)")
  }
  # Family-type filter scopes.
  scope :root_parents, -> {
    where(parent_product_id: nil)
      .where("EXISTS (SELECT 1 FROM products c WHERE c.parent_product_id = products.id)")
  }
  scope :children,   -> { where.not(parent_product_id: nil) }
  scope :standalone, -> {
    where(parent_product_id: nil)
      .where("NOT EXISTS (SELECT 1 FROM products c WHERE c.parent_product_id = products.id)")
  }
  # Products whose total movement stock is at or below their reorder_level.
  # Uses a correlated subquery — adequate for catalog sizes typical in this app.
  scope :low_stock, -> {
    low_stock_notifiable.where(
      "products.reorder_level > 0 AND products.reorder_level >= (" \
      "  SELECT COALESCE(SUM(CASE WHEN im.direction = 'in' THEN im.quantity ELSE -im.quantity END), 0)" \
      "  FROM inventory_movements im" \
      "  WHERE im.product_id = products.id" \
      ")"
    )
  }

  # True when this product has child products (is a family container).
  def parent?
    child_products.loaded? ? child_products.any? : child_products.exists?
  end

  # True when this product belongs to a parent family.
  def child?
    parent_product_id?
  end

  # Total on-hand across all warehouses, derived from the movement ledger.
  # Movements are the source of truth — this is never edited directly.
  def current_stock
    Inventory::StockLevels.new(self).total
  end

  # On-hand quantity in a single warehouse.
  def stock_in(warehouse)
    Inventory::StockLevels.new(self).in_warehouse(warehouse)
  end

  def low_stock?
    track_inventory? && current_stock <= low_stock_level
  end

  # Warehouse-specific threshold, falling back to the product-level default
  # when no per-warehouse override is configured.
  def low_stock_level_for(warehouse)
    setting_for(warehouse)&.low_stock_level || low_stock_level
  end

  def reorder_quantity_for(warehouse)
    setting_for(warehouse)&.reorder_quantity || reorder_quantity
  end

  # True when this product is at/below its threshold IN the given warehouse.
  def low_stock_in?(warehouse)
    track_inventory? && stock_in(warehouse) <= low_stock_level_for(warehouse)
  end

  def setting_for(warehouse)
    warehouse_id = warehouse.respond_to?(:id) ? warehouse.id : warehouse
    product_warehouse_settings.detect { |s| s.warehouse_id == warehouse_id }
  end

  def stock_value
    current_stock * average_cost_price
  end

  # Suggested selling price from the current average cost + markup.
  def selling_price
    average_cost_price * (1 + (selling_markup_percentage / 100))
  end

  def archived?
    !active?
  end

  def archive!
    if parent? && child_products.where(active: true).exists?
      errors.add(:base, :archive_has_active_children)
      raise ActiveRecord::RecordInvalid, self
    end
    update!(active: false, archived_at: Time.current)
  end

  def restore!
    update!(active: true, archived_at: nil)
  end

  # Archive this parent and all its active children in one call.
  def archive_family!
    transaction do
      child_products.where(active: true).find_each(&:archive!)
      update!(active: false, archived_at: Time.current)
    end
  end

  def has_inventory_history?
    inventory_movements.exists? ||
      goods_receipt_items.exists? ||
      stock_issue_items.exists? ||
      stock_transfer_items.exists? ||
      stock_adjustment_items.exists? ||
      stock_count_items.exists? ||
      product_barcodes.exists?
  end

  # Forces parent's track_inventory to false via update! so all callbacks and
  # audit trails fire. Guards against no-op saves.
  def force_non_tracking!
    return unless track_inventory? || receive_low_stock_notification?
    update!(track_inventory: false, receive_low_stock_notification: false)
  end

  # Returns the primary barcode value (or first barcode if none marked primary).
  # Overrides the legacy products.barcode column reader — product_barcodes is now
  # the source of truth.
  def barcode
    if association(:product_barcodes).loaded?
      (product_barcodes.find(&:is_primary?) || product_barcodes.reject(&:marked_for_destruction?).first)&.barcode
    else
      product_barcodes.where(is_primary: true).pick(:barcode) ||
      product_barcodes.order(:id).pick(:barcode)
    end
  end

  # Compat setter so single-barcode code paths (CSV import, seeds, controller
  # new action) continue to work: builds or updates the primary ProductBarcode.
  def barcode=(value)
    value = value.to_s.strip.presence
    return if value.nil?

    existing = product_barcodes.find(&:is_primary?) ||
               product_barcodes.detect { |b| b.barcode.to_s.downcase == value.downcase }
    if existing
      existing.barcode    = value
      existing.is_primary = true
    else
      product_barcodes.build(barcode: value, is_primary: true)
    end
  end

  private

  def enforce_parent_not_tracked
    is_parent = child_products.loaded? ? child_products.any? : child_products.exists?
    if is_parent
      self.track_inventory              = false
      self.receive_low_stock_notification = false
    end
  end

  def propagate_non_tracking_to_parent
    parent_product&.force_non_tracking!
  end

  # Ensures at most one barcode is marked primary before the nested records save.
  # If multiple are checked (e.g., JS disabled), keeps the last one. Auto-promotes
  # Generates a primary barcode via the business sequence when the product was
  # created without any barcodes. The DB check (exists?) is authoritative because
  # nested product_barcodes are committed before after_create fires.
  def auto_generate_barcode
    return if parent?
    return if product_barcodes.exists?
    Inventory::BusinessBarcodeGenerator.new(business).call(self)
  end

  # Enforces a single primary barcode per product.
  # If multiple are marked primary, keep the first; if none, promote the oldest.
  def ensure_single_primary_barcode
    active = product_barcodes.reject(&:marked_for_destruction?)
    return if active.empty?

    primaries = active.select(&:is_primary?)
    if primaries.size > 1
      primaries[0..-2].each { |pb| pb.is_primary = false }
    elsif primaries.empty?
      active.min_by { |pb| pb.id || Float::INFINITY }.is_primary = true
    end
  end
end
