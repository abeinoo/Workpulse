class CreatePayrollLineItems < ActiveRecord::Migration[8.1]
  def change
    create_table :payroll_line_items do |t|
      t.references :payroll_entry, null: false, foreign_key: true
      t.string  :item_type,   null: false
      t.string  :description
      t.decimal :amount,      precision: 12, scale: 2, null: false
      t.string  :source_type
      t.bigint  :source_id
      t.timestamps
    end

    add_index :payroll_line_items, [ :source_type, :source_id ]
  end
end
