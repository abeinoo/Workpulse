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

  has_many :goods_receipt_items, dependent: :restrict_with_error
  has_many :stock_issue_items,   dependent: :restrict_with_error
  has_many :inventory_movements, dependent: :restrict_with_error
  has_many :product_warehouse_settings, dependent: :destroy
  has_many :configured_warehouses, through: :product_warehouse_settings, source: :warehouse
  has_many :product_barcodes,   dependent: :destroy
  has_many :product_variants,   dependent: :destroy

  accepts_nested_attributes_for :product_warehouse_settings,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:warehouse_id].blank? }
  accepts_nested_attributes_for :product_barcodes,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:barcode].blank? }
  accepts_nested_attributes_for :product_variants,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:name].blank? }

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

  before_save :ensure_single_primary_barcode

  scope :for_business,       ->(business) { where(business: business) }
  scope :ordered,            -> { order(:name) }
  scope :inventory_tracked,  -> { where(track_inventory: true) }
  scope :low_stock_notifiable, -> { inventory_tracked.where(receive_low_stock_notification: true) }
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

  # Ensures at most one barcode is marked primary before the nested records save.
  # If multiple are checked (e.g., JS disabled), keeps the last one. Auto-promotes
  # the first active barcode when none is marked.
  # Enforces a single primary barcode per (product, variant_id) group.
  # variant_id = nil means the barcode belongs to the product itself.
  def ensure_single_primary_barcode
    active = product_barcodes.reject(&:marked_for_destruction?)
    return if active.empty?

    active.group_by(&:variant_id).each_value do |group|
      primaries = group.select(&:is_primary?)
      if primaries.size > 1
        primaries[0..-2].each { |pb| pb.is_primary = false }
      elsif primaries.empty?
        group.min_by { |pb| pb.id || Float::INFINITY }.is_primary = true
      end
    end
  end
end
