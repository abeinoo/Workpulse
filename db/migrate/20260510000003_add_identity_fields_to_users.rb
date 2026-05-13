class AddIdentityFieldsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :identity_card_number,      :string
    add_column :users, :identity_card_expiry_date, :date
    add_index  :users, :identity_card_number, unique: true
  end
end
