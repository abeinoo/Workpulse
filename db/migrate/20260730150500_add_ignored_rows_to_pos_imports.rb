class AddIgnoredRowsToPosImports < ActiveRecord::Migration[8.1]
  def change
    add_column :pos_imports, :ignored_rows, :integer, default: 0, null: false
    add_column :pos_imports, :ignored_amount, :decimal, precision: 12, scale: 2, default: "0.0", null: false
  end
end
