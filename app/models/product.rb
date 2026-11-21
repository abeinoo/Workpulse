class Product < ApplicationRecord
  include Attachable

  # Retired product-level stock settings. Low-stock threshold, reorder
  # quantity and the low-stock notification are per warehouse only
  # (ProductWarehouseSetting); the product never has one, and nothing falls
  # back to these columns. They stay in the table until a reviewed migration
  # drops them; ignoring them here makes any remaining read or write fail
  # loudly instead of silently using a stale value.
  self.ignored_columns += %w[low_stock_level reorder_quantity reorder_level receive_low_stock_notification]
  # Retired Product Family (parent / child products): every product stands on
  # its own. The column stays until a reviewed migration drops it.
  self.ignored_columns += %w[parent_product_id]

  # The image gallery (Inventory::ProductGalleryUpdater): ordered images, the
  # first being the primary image used wherever the product's image is shown.
  # Preload with IMAGE_PRELOAD / with_primary_image (ProductThumbnailHelper
  # refuses an image that was not preloaded in tests — no N+1 on long lists).
  has_many :images, -> { order(:position, :id) }, class_name: "ProductImage",
                                                  inverse_of: :product, dependent: :destroy
  has_one  :primary_image, -> { order(:position, :id) }, class_name: "ProductImage"
  IMAGE_PRELOAD = { primary_image: { file_attachment: :blob } }.freeze

  belongs_to :business
  belongs_to :brand,            optional: true
  belongs_to :product_category, optional: true
  belongs_to :default_supplier, class_name: "Supplier", optional: true

  has_many :goods_receipt_items,   dependent: :restrict_with_error
  has_many :stock_issue_items,     dependent: :restrict_with_error
  has_many :stock_transfer_items,  dependent: :restrict_with_error
  has_many :stock_adjustment_items, dependent: :restrict_with_error
  has_many :stock_count_items,     dependent: :restrict_with_error
  has_many :inventory_movements,   dependent: :restrict_with_error
  # Availability rows are configuration history: a product that has any is
  # never deleted (Inventory::ProductDeletion refuses; this is the backstop).
  has_many :product_warehouse_settings, dependent: :restrict_with_error
  has_many :configured_warehouses, through: :product_warehouse_settings, source: :warehouse
  has_many :product_barcodes,   dependent: :destroy

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
  validates :selling_markup_percentage,
            numericality: { greater_than_or_equal_to: 0 }
  # Display-only — no conversion math anywhere in the app. A product's
  # quantities (receipts, issues, transfers, laundry consumption) are always
  # in this one unit; never mix e.g. kg and g on the same product.
  UNITS_OF_MEASURE = %w[pieces kg g l ml].freeze
  validates :unit_of_measure, inclusion: { in: UNITS_OF_MEASURE }
  # "Track stock quantity" stays on while the product still holds stock or is
  # on an open inventory document (Inventory::TrackingDependencies): an
  # untracked product drops out of counts, alerts and reorder settings, so
  # stock must never silently leave inventory management.
  validate :tracking_kept_while_stock_or_documents, on: :update
  validate :default_supplier_in_same_business, if: :default_supplier_id?
  validate :brand_in_same_business,            if: :brand_id?
  validate :product_category_in_same_business, if: :product_category_id?

  # The default supplier must belong to the product's business (SEC-P6-2) —
  # the PurchaseRequest / GoodsReceipt supplier_in_same_business rule.
  def default_supplier_in_same_business
    return if default_supplier.nil? || business_id.nil?

    errors.add(:default_supplier, :invalid) if default_supplier.business_id != business_id
  end

  # The brand must belong to the product's business (SEC-P6-4).
  def brand_in_same_business
    return if brand.nil? || business_id.nil?

    errors.add(:brand, :invalid) if brand.business_id != business_id
  end

  # The category must belong to the product's business (SEC-P6-5).
  def product_category_in_same_business
    return if product_category.nil? || business_id.nil?

    errors.add(:product_category, :invalid) if product_category.business_id != business_id
  end

  before_save :ensure_single_primary_barcode

  # Auto-generate a primary barcode when the product is created with no barcodes.
  # Fires after nested product_barcodes are already saved, so the check is accurate.
  after_create :auto_generate_barcode

  scope :for_business,       ->(business) { where(business: business) }
  scope :with_primary_image, -> { includes(IMAGE_PRELOAD) }
  scope :ordered,            -> { order(:name) }
  scope :active,             -> { where(active: true) }
  scope :archived,           -> { where(active: false) }
  scope :inventory_tracked,  -> { where(track_inventory: true) }
  # Products that may appear on inventory document lines: every active product.
  scope :transactable,       -> { active }

  # Total on-hand across all warehouses, derived from the movement ledger.
  # Movements are the source of truth — this is never edited directly.
  def current_stock
    Inventory::StockLevels.new(self).total
  end

  # On-hand quantity in a single warehouse.
  def stock_in(warehouse)
    Inventory::StockLevels.new(self).in_warehouse(warehouse)
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
    update!(active: false, archived_at: Time.current)
  end

  def restore!
    update!(active: true, archived_at: nil)
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

  def tracking_kept_while_stock_or_documents
    return unless will_save_change_to_track_inventory?(from: true, to: false)

    blockers = Inventory::TrackingDependencies.new(self).blockers
    return if blockers.empty?

    details = blockers.map { |key, count| I18n.t("activerecord.errors.models.product.tracking_blockers.#{key}", count: count) }
    errors.add(:track_inventory, :tracking_in_use, details: details.to_sentence)
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

  # { product_id => barcode } for many products in ONE query, with exactly
  # #barcode's selection rule: the primary barcode, else the first (lowest id)
  # barcode; products without any are absent. For list/form rendering, where
  # calling #barcode per product would query once or twice per product.
  def self.barcode_lookup(product_ids)
    ids = Array(product_ids).compact.uniq
    return {} if ids.empty?

    ProductBarcode.where(product_id: ids)
                  .order(:product_id, is_primary: :desc, id: :asc)
                  .pluck(:product_id, :barcode)
                  .each_with_object({}) { |(product_id, barcode), map| map[product_id] ||= barcode }
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
  # Generates a primary barcode via the business sequence when the product was
  # created without any barcodes. The DB check (exists?) is authoritative because
  # nested product_barcodes are committed before after_create fires.
  def auto_generate_barcode
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
