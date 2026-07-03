class CreatePosImports < ActiveRecord::Migration[8.0]
  def change
    create_table :pos_imports do |t|
      t.references :business,             null: false, foreign_key: true
      t.references :daily_reconciliation, null: false, foreign_key: true
      t.references :imported_by,          null: false, foreign_key: { to_table: :users }
      t.string  :file_name,    null: false
      t.string  :status,       null: false, default: "pending"
      t.jsonb   :column_mapping, null: false, default: {}
      t.integer :total_rows,   null: false, default: 0
      t.integer :failed_rows,  null: false, default: 0
      t.timestamps
    end

    add_index :pos_imports, :status
    add_index :pos_imports, :daily_reconciliation_id, unique: true,
              name: "index_pos_imports_on_daily_reconciliation_id_unique"
  end
end
