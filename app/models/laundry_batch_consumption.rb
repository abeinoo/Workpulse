# A material-consumption record, linking the InventoryMovement that consumed
# material from a laundry warehouse to either a LaundryBatch (legacy/advanced
# batch workflow, via Laundry::BatchMaterialConsumer) or directly to a laundry
# Branch. Exactly one of laundry_batch_id / laundry_branch_id is ever set.
#
# NOTE: this is no longer a recording entry point — the existing Inventory
# Stock Issue workflow is the single source of truth for laundry material
# consumption cost (see Laundry::LaundryCostSummaryReport). Any orphaned
# laundry_branch_id-only rows here are historical data from a removed
# standalone recording screen and are not counted by that report.
#
# unit_cost_snapshot/total_cost_snapshot are frozen at posting time
# (copy-on-write), so a later change to Product#average_cost_price never
# alters a historical consumption's cost — mirrors StockIssueItem/StockTransferItem.
class LaundryBatchConsumption < ApplicationRecord
  belongs_to :laundry_batch, optional: true
  belongs_to :laundry_branch, class_name: "Branch", optional: true
  belongs_to :product
  belongs_to :inventory_movement

  validates :quantity, numericality: { greater_than: 0 }
  validates :unit_cost_snapshot, :total_cost_snapshot,
            numericality: { greater_than_or_equal_to: 0 }
  validate :exactly_one_of_batch_or_branch

  # The laundry branch this consumption is attributable to, regardless of
  # which workflow created it.
  def branch
    laundry_batch ? laundry_batch.laundry_branch : laundry_branch
  end

  private

  def exactly_one_of_batch_or_branch
    return if laundry_batch_id.present? ^ laundry_branch_id.present?

    errors.add(:base, :batch_or_branch_required)
  end
end
