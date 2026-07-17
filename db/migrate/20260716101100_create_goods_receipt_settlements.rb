class CreateGoodsReceiptSettlements < ActiveRecord::Migration[8.1]
  # Financial settlement becomes its own append-only ledger, independent of the
  # goods_receipts.status inventory lifecycle. financial_status is now derived
  # from SUM(amount) across these rows vs. the receipt total — never stored —
  # so the stored financial_status column added earlier this session is dropped.
  def up
    create_table :goods_receipt_settlements do |t|
      t.references :goods_receipt, null: false, foreign_key: true
      t.references :funding_source, polymorphic: true, null: false
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.datetime :settled_at, null: false
      t.references :created_by, foreign_key: { to_table: :users }, null: true
      t.text :notes
      t.timestamps
    end

    remove_column :goods_receipts, :financial_status
  end

  def down
    add_column :goods_receipts, :financial_status, :string, null: false, default: "pending_settlement"
    drop_table :goods_receipt_settlements
  end
end
