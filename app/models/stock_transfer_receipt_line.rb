# The quantity of one transfer line received in one StockTransferReceipt.
# Append-only (stock_transfer_receipt_lines_append_only).
class StockTransferReceiptLine < ApplicationRecord
  belongs_to :stock_transfer_receipt, inverse_of: :lines
  belongs_to :stock_transfer_item

  validates :quantity, numericality: { greater_than: 0 }

  def readonly? = persisted?
end
