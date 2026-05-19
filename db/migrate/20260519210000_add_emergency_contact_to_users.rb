class AddEmergencyContactToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :emergency_contact_name,         :string
    add_column :users, :emergency_contact_phone,        :string
    add_column :users, :emergency_contact_relationship, :string
  end
end
