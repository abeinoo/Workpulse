# One receipt of a via-transit stock transfer at its destination (Stock
# Transfer redesign, Phase C): who received, when (time and Business Day) and,
# per line, how much (StockTransferReceiptLine). Written only by
# Inventory::StockTransferReceiving together with the transit -> destination
# movements; append-only — the database refuses UPDATE and DELETE
# (stock_transfer_receipts_append_only).
#
# closes_with_shortfall: the receiver declared that nothing more will arrive;
# the transfer's remaining quantities then await a discrepancy resolution.
class StockTransferReceipt < ApplicationRecord
  belongs_to :business
  belongs_to :stock_transfer
  belongs_to :received_by, class_name: "User"
  has_many :lines, class_name: "StockTransferReceiptLine", dependent: :restrict_with_exception,
                   inverse_of: :stock_transfer_receipt

  validates :received_at, :received_on, presence: true

  def readonly? = persisted?
end
