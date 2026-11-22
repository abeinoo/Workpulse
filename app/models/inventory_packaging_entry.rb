# Append-only packaging ledger (docs/inventory/multi_unit_nested_packaging_design.md §5).
# Free (sealed, not inside a larger free package) packages of a level in a
# warehouse = SUM(package_delta). Total stock and cost stay in
# inventory_movements; an entry never moves quantity or money:
#
#   moved            packages that physically entered (+) / left (−) with a movement
#   breakdown        an opened package (−) and the packages it releases (+) — never reversed
#   count_correction a stocktake packaging difference — reversed by reopening the count
#   conversion       reserved for the Unit Conversion document (P6)
#
# Written only by Inventory::Packaging::EntryWriter; UPDATE / DELETE are refused
# by a database trigger.
class InventoryPackagingEntry < ApplicationRecord
  KINDS = %w[moved breakdown count_correction conversion].freeze

  belongs_to :business
  belongs_to :product
  belongs_to :warehouse
  belongs_to :packaging_level, class_name: "ProductPackagingLevel"
  belongs_to :inventory_movement, optional: true
  belongs_to :source, polymorphic: true, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :package_delta, numericality: { only_integer: true, other_than: 0 }
  validates :occurred_on, presence: true

  def readonly? = persisted?
end
