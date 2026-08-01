class CreatePosImportsTable < ActiveRecord::Migration[8.1]
  def change
    create_table :pos_imports do |t|
      t.references :business,    null: false, foreign_key: true
      t.references :imported_by, null: false, foreign_key: { to_table: :users }
      t.string  :file_name, null: false
      t.string  :status, null: false, default: "pending"

      t.integer :total_rows,             null: false, default: 0
      t.integer :imported_rows,          null: false, default: 0
      t.integer :duplicate_rows,         null: false, default: 0
      t.integer :invalid_rows,           null: false, default: 0
      t.integer :unknown_terminal_rows,  null: false, default: 0
      t.integer :expenses_created_count, null: false, default: 0
      t.decimal :total_amount, precision: 12, scale: 2, null: false, default: 0
      t.decimal :total_fees,   precision: 12, scale: 2, null: false, default: 0

      t.jsonb :preview_data, default: {}

      t.timestamps
    end

    add_index :pos_imports, :status
  end
end
