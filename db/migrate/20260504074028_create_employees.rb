class CreateEmployees < ActiveRecord::Migration[8.1]
  def change
    create_table :employees do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :phone_number, null: false
      t.string :employee_number, null: false
      t.string :full_name, null: false
      t.string :department
      t.string :job_title
      t.date :hire_date
      t.integer :status, null: false, default: 0
      t.integer :manager_id

      t.timestamps
    end

    add_index :employees, :phone_number, unique: true
    add_index :employees, :employee_number, unique: true
    add_index :employees, :manager_id
  end
end
