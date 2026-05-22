class AddCurrencyToBusinesses < ActiveRecord::Migration[8.1]
  def change
    add_column :businesses, :currency, :string, null: false, default: "SAR"
  end
end
