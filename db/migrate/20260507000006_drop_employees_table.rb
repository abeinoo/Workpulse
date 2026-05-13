class DropEmployeesTable < ActiveRecord::Migration[8.1]
  def up
    drop_table :employees
  end

  def down
    create_table :employees do |t|
      t.string  :full_name,        null: false
      t.string  :employee_number,  null: false
      t.string  :phone_number,     null: false
      t.string  :email
      t.string  :job_title
      t.string  :department
      t.date    :hire_date
      t.integer :manager_id
      t.integer :status, default: 0, null: false
      t.timestamps
    end
    add_index :employees, :phone_number, unique: true
    add_index :employees, :email,        unique: true
  end
end
