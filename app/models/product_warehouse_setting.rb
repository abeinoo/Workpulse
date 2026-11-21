# A product's availability in ONE warehouse, with that warehouse's own
# low-stock settings. One row per (product, warehouse):
#
#   no row             Not Configured — the product is not used there
#   status "active"    Active — used there; low_stock_level / reorder_quantity /
#                      receive_low_stock_notification apply to that warehouse only
#   status "inactive"  Inactive — no longer used there; the settings are kept
#                      so a reactivation restores them (status_reason / status_changed_*)
#
# There is no product-wide default: a warehouse without a row never inherits
# another warehouse's (or the product's legacy) values. A threshold of 0
# means no low-stock detection for that warehouse. receive_low_stock_notification
# controls dashboard notification surfaces only — never detection.
#
# State changes go through Inventory::ProductAvailabilityManager (audited).
class ProductWarehouseSetting < ApplicationRecord
  STATUSES = %w[active inactive].freeze

  belongs_to :product
  belongs_to :warehouse
  belongs_to :business
  belongs_to :status_changed_by, class_name: "User", optional: true
  belongs_to :created_by,        class_name: "User", optional: true
  belongs_to :updated_by,        class_name: "User", optional: true

  enum :status, STATUSES.index_with(&:itself), prefix: true, validate: true

  before_validation :inherit_business_from_product

  validates :warehouse_id, uniqueness: { scope: :product_id }
  validates :low_stock_level, :reorder_quantity,
            numericality: { greater_than_or_equal_to: 0 }
  validates :status_reason, presence: true, if: :status_inactive?
  validate :warehouse_in_same_business
  validate :business_matches_product
  validate :inactive_row_unchanged, on: :update

  # An Inactive row is never deleted: without it the pair would read as Not
  # Configured and incoming stock would no longer be refused (backstop for
  # nested attributes; the product form never submits Inactive rows).
  before_destroy :refuse_destroying_inactive_row

  scope :for_business, ->(business) { where(business_id: business.respond_to?(:id) ? business.id : business) }

  private

  # While a row stays Inactive its warehouse and kept settings don't change
  # (reactivation restores them); the status change itself may carry them.
  def inactive_row_unchanged
    return unless status_in_database == "inactive" && !will_save_change_to_status?

    frozen = %w[product_id warehouse_id business_id low_stock_level reorder_quantity receive_low_stock_notification]
    errors.add(:base, :inactive_row_locked) if frozen.any? { |attr| will_save_change_to_attribute?(attr) }
  end

  def refuse_destroying_inactive_row
    return unless status_in_database == "inactive"

    errors.add(:base, :inactive_row_locked)
    throw :abort
  end

  def inherit_business_from_product
    self.business_id ||= product&.business_id
  end

  def warehouse_in_same_business
    return if warehouse.nil? || product.nil?
    errors.add(:warehouse_id, :different_business) if warehouse.business_id != product.business_id
  end

  def business_matches_product
    return if product.nil? || business_id.nil?
    errors.add(:business_id, :different_business) if business_id != product.business_id
  end
end
