# The resolution of (part of) a transfer line's quantity that will not be
# received (Stock Transfer redesign, decision D3): returned to the source
# warehouse, or written off as lost — always with a reason. Written only by
# Inventory::StockTransferDiscrepancyResolution together with its movements;
# append-only (stock_transfer_resolutions_append_only).
class StockTransferResolution < ApplicationRecord
  KINDS = %w[return_to_source write_off].freeze

  belongs_to :business
  belongs_to :stock_transfer
  belongs_to :stock_transfer_item
  belongs_to :resolved_by, class_name: "User"

  enum :kind, KINDS.index_with(&:itself), prefix: true, validate: true

  validates :quantity, numericality: { greater_than: 0 }
  validates :reason, presence: true
  validates :resolved_at, :resolved_on, presence: true

  def readonly? = persisted?
end
