class CreatePaymentMethods < ActiveRecord::Migration[8.1]
  def change
    create_table :payment_methods do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name,             null: false
      t.string  :name_ar
      t.string  :payment_category, null: false, default: "other"
      t.boolean :active,           null: false, default: true
      t.integer :position,         null: false, default: 0

      t.timestamps
    end

    add_index :payment_methods,
              "business_id, lower(name)",
              name: "index_payment_methods_on_business_id_and_lower_name",
              unique: true

    add_index :payment_methods,
              %i[business_id active position],
              name: "index_payment_methods_on_business_id_and_active_and_position"

    add_index :payment_methods,
              %i[business_id payment_category],
              name: "idx_payment_methods_on_business_and_category"
  end
end
