class ReworkAuthSchema < ActiveRecord::Migration[8.1]
  def change
    # --- employees: remove user FK, tighten constraints ---
    remove_foreign_key :employees, :users
    remove_column :employees, :user_id, :integer

    change_column_null :employees, :employee_number, false
    change_column_null :employees, :full_name, false
    change_column_null :employees, :status, false
    change_column_default :employees, :status, from: nil, to: 0

    # --- users: drop legacy auth columns ---
    remove_column :users, :phone_number, :string
    remove_column :users, :otp_code, :string
    remove_column :users, :otp_sent_at, :datetime

    # --- users: add Devise columns ---
    add_reference :users, :employee, null: false, foreign_key: true, index: { unique: true }
    add_column :users, :encrypted_password,      :string,   null: false, default: ""
    add_column :users, :reset_password_token,    :string
    add_column :users, :reset_password_sent_at,  :datetime
    add_column :users, :remember_created_at,     :datetime

    add_index :users, :reset_password_token, unique: true
  end
end
