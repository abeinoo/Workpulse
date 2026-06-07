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

  accepts_nested_attributes_for :product_warehouse_settings,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:warehouse_id].blank? }

  validates :name, presence: true, length: { maximum: 200 }
  validates :sku,  presence: true, length: { maximum: 80 }
  validates :sku,  uniqueness: { scope: :business_id, case_sensitive: false }
  validates :barcode,
            uniqueness: { scope: :business_id, case_sensitive: false },
            allow_blank: true
  validates :initial_cost_price, :average_cost_price,
            numericality: { greater_than_or_equal_to: 0 }
  validates :last_purchase_price,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :low_stock_level, :reorder_quantity,
            numericality: { greater_than_or_equal_to: 0 }
  validates :selling_markup_percentage,
            numericality: { greater_than_or_equal_to: 0 }

  before_validation :normalize_blank_barcode

  scope :for_business, ->(business) { where(business: business) }
  scope :ordered,      -> { order(:name) }

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
    current_stock <= low_stock_level
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
    stock_in(warehouse) <= low_stock_level_for(warehouse)
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

  private

  def normalize_blank_barcode
    self.barcode = nil if barcode.blank?
  end
end
