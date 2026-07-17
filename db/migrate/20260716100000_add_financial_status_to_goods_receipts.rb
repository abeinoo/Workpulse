class AddFinancialStatusToGoodsReceipts < ActiveRecord::Migration[8.1]
  # Financial settlement is a separate concern from inventory posting — this
  # column is added but not yet wired to any settlement logic. Every receipt,
  # old and new, starts "pending_settlement"; nothing about existing confirmed
  # receipts' stock/custody state changes.
  def change
    add_column :goods_receipts, :financial_status, :string, null: false, default: "pending_settlement"
  end
end
