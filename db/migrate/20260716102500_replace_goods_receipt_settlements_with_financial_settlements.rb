class ReplaceGoodsReceiptSettlementsWithFinancialSettlements < ActiveRecord::Migration[8.1]
  # goods_receipt_settlements had zero rows in production at the time of this
  # migration (the feature shipped moments earlier in the same release) — a
  # clean drop/recreate is safe and far simpler than an in-place polymorphic
  # rename. FinancialSettlement generalizes the ledger to any "settleable"
  # document (GoodsReceipt today; PurchaseInvoice, Expense, Payroll, etc. later)
  # instead of being hard-wired to goods_receipt_id.
  def up
    drop_table :goods_receipt_settlements

    create_table :financial_settlements do |t|
      t.references :settleable, polymorphic: true, null: false
      t.references :funding_source, polymorphic: true, null: false
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.datetime :settled_at, null: false
      t.references :created_by, foreign_key: { to_table: :users }, null: true
      t.text :notes
      t.timestamps
    end
  end

  def down
    drop_table :financial_settlements

    create_table :goods_receipt_settlements do |t|
      t.references :goods_receipt, null: false, foreign_key: true
      t.references :funding_source, polymorphic: true, null: false
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.datetime :settled_at, null: false
      t.references :created_by, foreign_key: { to_table: :users }, null: true
      t.text :notes
      t.timestamps
    end
  end
end
