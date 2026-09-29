# Explicit supply relationship: this warehouse supplies (serves) this branch.
# Configuration for branch-level reporting only — stock is still owned by the
# warehouse and nothing here holds, allocates or moves stock.
#
# One row per branch (unique branch_id) = the branch's primary supplying
# warehouse; a warehouse may supply many branches. An inactive row is kept for
# history but ignored — the branch then falls back to the ledger-inferred
# relationship (Inventory::BranchSupplyMap). Created and changed only through
# Inventory::WarehouseSupplyAssigner (audit-logged).
class WarehouseBranchSupply < ApplicationRecord
  belongs_to :business
  belongs_to :warehouse
  belongs_to :branch
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  validates :branch_id, uniqueness: true
  validate :same_business

  scope :active, -> { where(active: true) }

  private

  def same_business
    errors.add(:warehouse, :invalid) if warehouse && warehouse.business_id != business_id
    errors.add(:branch, :invalid)    if branch && branch.business_id != business_id
  end
end
