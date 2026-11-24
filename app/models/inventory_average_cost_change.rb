# The audit record of every change to a product's stored average cost
# (Decision 17). Written by
# Inventory::AverageCost in the same transaction as the change; append-only
# (database trigger). system = true marks automated runs (no user, or a job).
class InventoryAverageCostChange < ApplicationRecord
  TRIGGERS = %w[receipt_posted opening_balance_posted document_voided manual_recalculation batch_replay].freeze

  belongs_to :business
  belongs_to :product
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :inventory_movement, optional: true
  belongs_to :source, polymorphic: true, optional: true

  validates :trigger, inclusion: { in: TRIGGERS }
  validates :previous_average_cost, :new_average_cost, presence: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def readonly? = persisted?
end
