class RestructureUsers < ActiveRecord::Migration[8.1]
  def change
    # Remove link to employees table
    remove_foreign_key :users, :employees, if_exists: true
    remove_column :users, :employee_id, :integer
    remove_column :users, :role,        :integer

    # Tie user to a business (tenant root)
    add_reference :users, :business, foreign_key: true

    # Profile columns
    add_column :users, :first_name,    :string
    add_column :users, :last_name,     :string
    add_column :users, :phone_number,  :string
    add_column :users, :employee_code, :string
    add_column :users, :role,          :string, null: false, default: "employee"
    add_column :users, :active,        :boolean, null: false, default: true

    add_index :users, :phone_number, unique: true
    add_index :users, :role
  end
end
