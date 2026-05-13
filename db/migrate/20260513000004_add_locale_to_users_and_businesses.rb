class AddLocaleToUsersAndBusinesses < ActiveRecord::Migration[8.1]
  def change
    add_column :businesses, :default_locale, :string, default: "en", null: false
    add_column :users, :preferred_locale, :string
  end
end
