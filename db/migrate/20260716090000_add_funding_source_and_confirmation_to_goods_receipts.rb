class AddFundingSourceAndConfirmationToGoodsReceipts < ActiveRecord::Migration[8.1]
  # Existing receipts were posted atomically under the old flow (no draft state
  # existed) — they must backfill as "confirmed", not "draft" (the new column
  # default), so historical documents aren't retroactively un-posted.
  def up
    add_column :goods_receipts, :status, :string, null: false, default: "draft"
    add_column :goods_receipts, :funding_source_kind, :string, null: false, default: "supplier_credit"
    add_reference :goods_receipts, :funding_source, polymorphic: true, null: true, index: true
    add_column :goods_receipts, :confirmed_at, :datetime
    add_reference :goods_receipts, :confirmed_by, null: true, foreign_key: { to_table: :users }, index: true

    add_reference :custody_transactions, :source, polymorphic: true, null: true, index: true

    execute "UPDATE goods_receipts SET status = 'confirmed', confirmed_at = created_at"
  end

  def down
    remove_reference :custody_transactions, :source, polymorphic: true

    remove_reference :goods_receipts, :confirmed_by, foreign_key: { to_table: :users }
    remove_column :goods_receipts, :confirmed_at
    remove_reference :goods_receipts, :funding_source, polymorphic: true
    remove_column :goods_receipts, :funding_source_kind
    remove_column :goods_receipts, :status
  end
end
