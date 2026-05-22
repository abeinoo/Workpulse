class CreateEmployeeObligations < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_obligations do |t|
      t.references :user,       null: false, foreign_key: true
      t.references :business,   null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }

      t.string  :obligation_type,    null: false
      t.string  :title,              null: false
      t.text    :description
      t.text    :notes

      t.decimal :total_amount,       precision: 12, scale: 2, null: false
      t.decimal :remaining_amount,   precision: 12, scale: 2, null: false
      t.decimal :installment_amount, precision: 12, scale: 2, null: false

      t.integer :start_month, null: false
      t.integer :start_year,  null: false
      t.integer :end_month
      t.integer :end_year

      t.string  :status,     null: false, default: "active"
      t.boolean :auto_deduct, null: false, default: true

      t.timestamps
    end

    add_index :employee_obligations, [ :user_id, :status ]
    add_index :employee_obligations, [ :business_id, :status ]
  end
end
