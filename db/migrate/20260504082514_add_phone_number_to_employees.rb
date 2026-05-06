class AddPhoneNumberToEmployees < ActiveRecord::Migration[8.1]
  def change
    add_column :employees, :phone_number, :string, null: false, default: ""
    add_index :employees, :phone_number, unique: true
    change_column_null :employees, :phone_number, false
    change_column_default :employees, :phone_number, from: "", to: nil
  end
end
