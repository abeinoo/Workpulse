class CreateAdvances < ActiveRecord::Migration[8.1]
  def change
    create_table :advances do |t|
      t.references :user,             null: false, foreign_key: true
      t.references :employee_request, null: false, foreign_key: true, index: { unique: true }
      t.decimal :total_amount,     precision: 12, scale: 2, null: false
      t.decimal :remaining_amount, precision: 12, scale: 2, null: false
      t.string  :status,           null: false, default: "active"
      t.datetime :issued_at,       null: false
      t.timestamps
    end

    add_index :advances, [ :user_id, :status ]
  end
end
