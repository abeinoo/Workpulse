class AddApprovalWorkflowToGoodsReceipts < ActiveRecord::Migration[8.1]
  # Approval (a purchasing decision) is independent of the existing
  # status (draft/confirmed, an inventory event) — see GoodsReceipt.
  # decided_by/decided_at cover both approve and reject outcomes: the show
  # page shows one "Approver" / "Approval Date" pair regardless of outcome.
  def change
    add_column :goods_receipts, :approval_status, :string, null: false, default: "draft"
    add_reference :goods_receipts, :decided_by, null: true, foreign_key: { to_table: :users }, index: true
    add_column :goods_receipts, :decided_at, :datetime
    add_column :goods_receipts, :rejection_reason, :text
  end
end
