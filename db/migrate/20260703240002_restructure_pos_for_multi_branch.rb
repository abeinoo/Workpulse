class RestructurePosForMultiBranch < ActiveRecord::Migration[8.0]
  def change
    # ── pos_imports: become business-level (not DR-level) ───────────────────
    remove_index  :pos_imports, name: "index_pos_imports_on_daily_reconciliation_id_unique"
    remove_column :pos_imports, :daily_reconciliation_id, :bigint

    add_column :pos_imports, :matched_rows,  :integer, null: false, default: 0
    add_column :pos_imports, :unmatched_rows, :integer, null: false, default: 0
    add_column :pos_imports, :dr_count,      :integer, null: false, default: 0

    # ── pos_transactions: gain branch_name + DR foreign key ─────────────────
    add_column :pos_transactions, :branch_name, :string
    add_reference :pos_transactions, :daily_reconciliation,
                  null: true, foreign_key: true, index: true

    add_index :pos_transactions, :branch_name
  end
end
