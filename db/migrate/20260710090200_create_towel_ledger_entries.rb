class CreateTowelLedgerEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :towel_ledger_entries do |t|
      t.references :business,   null: false, foreign_key: true
      t.references :towel_type, null: false, foreign_key: true
      # Physical location of the towels this row moves — any Branch, including
      # a branch_type: "laundry" branch. There is no separate "in_laundry"
      # status: it's simply a clean/dirty balance where branch_id is the
      # laundry's branch. "In transit" is likewise not a ledger balance — it is
      # derived from open TowelTransfer rows.
      t.references :branch,     null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :source, polymorphic: true

      t.string   :direction,   null: false
      t.string   :status,      null: false
      t.string   :reason,      null: false
      t.decimal  :quantity,    precision: 12, scale: 3, null: false
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :towel_ledger_entries, [ :branch_id, :status ]
    add_index :towel_ledger_entries, [ :business_id, :occurred_at ]
    add_index :towel_ledger_entries, [ :towel_type_id, :branch_id, :status ],
              name: "index_towel_ledger_on_type_branch_status"
  end
end
