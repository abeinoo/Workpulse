# One level of a product's packaging chain (docs/inventory/multi_unit_nested_packaging_design.md §4):
# position 1 is the innermost package (its contains_quantity is in the
# product's base unit, e.g. 355 ml in a bottle, 10 pieces in a box), each
# higher level contains a whole number of the level below (12 boxes in a
# carton). base_quantity is the whole chain in base units (a carton = 120 pcs).
#
# A level is never edited (database trigger): it is retired and replaced, only
# through Inventory::Packaging::Configurator. At most four active levels.
class ProductPackagingLevel < ApplicationRecord
  PACKAGE_UNITS = %w[bottle can jar tube bag sachet box pack carton case pallet].freeze
  MAX_LEVELS    = 4
  STATUSES      = %w[active retired].freeze

  belongs_to :business
  belongs_to :product
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :retired_by, class_name: "User", optional: true

  scope :active,  -> { where(status: "active") }
  scope :ordered, -> { order(:position) }

  validates :position, numericality: { only_integer: true, in: 1..MAX_LEVELS }
  validates :package_unit, inclusion: { in: PACKAGE_UNITS }
  validates :contains_quantity, numericality: { greater_than: 0 }
  validates :base_quantity, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }
  validate  :outer_levels_contain_whole_packages
  validate  :same_business

  def active? = status == "active"

  private

  def outer_levels_contain_whole_packages
    return if position.to_i <= 1 || contains_quantity.nil?

    errors.add(:contains_quantity, :not_an_integer) unless contains_quantity == contains_quantity.to_i
  end

  def same_business
    return if product.nil? || business_id.nil?

    errors.add(:product_id, :other_business) if product.business_id != business_id
  end
end
