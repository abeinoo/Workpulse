class LinkPurchaseRequestsToGoodsReceipts < ActiveRecord::Migration[8.1]
  # Completes the PurchaseRequest approval workflow (submit/approve/reject/
  # cancel — same column shape as StockIssue's) and links a Goods Receipt back
  # to the Purchase Request line it fulfils, so received/remaining quantities
  # can be computed per PurchaseRequestItem without ambiguity when a product
  # appears on more than one request. Both new FKs are nullable: historical
  # GoodsReceipts/GoodsReceiptItems have no Purchase Request and must keep
  # working unchanged.
  def change
    change_table :purchase_requests, bulk: true do |t|
      t.datetime :submitted_at
      t.references :submitted_by, foreign_key: { to_table: :users }, null: true
      t.datetime :approved_at
      t.references :approved_by, foreign_key: { to_table: :users }, null: true
      t.datetime :rejected_at
      t.references :rejected_by, foreign_key: { to_table: :users }, null: true
      t.text :rejection_reason
      t.datetime :cancelled_at
      t.references :cancelled_by, foreign_key: { to_table: :users }, null: true
      t.text :cancellation_reason
    end

    add_reference :goods_receipts, :purchase_request, foreign_key: true, null: true
    add_reference :goods_receipt_items, :purchase_request_item, foreign_key: true, null: true
  end
end
