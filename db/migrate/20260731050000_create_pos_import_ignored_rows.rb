class CreatePosImportIgnoredRows < ActiveRecord::Migration[8.1]
  def change
    create_table :pos_import_ignored_rows do |t|
      t.references :pos_import, null: false, foreign_key: true
      t.references :business,   null: false, foreign_key: true
      t.references :ignored_by, null: false, foreign_key: { to_table: :users }
      t.integer :row_number, null: false
      t.text    :reason,     null: false

      t.timestamps
    end

    add_index :pos_import_ignored_rows, [ :pos_import_id, :row_number ], unique: true,
              name: "idx_pos_import_ignored_rows_on_import_and_row"
  end
end
