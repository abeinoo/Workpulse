class CreateExpenseCatalogTables < ActiveRecord::Migration[8.1]
  # Catalog layer for the Financial Operations module: categories → types, plus
  # free-form tags. All business-scoped with case-insensitive uniqueness, mirroring
  # the inventory catalog (brands / product_categories).
  def change
    create_table :expense_categories do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name,        null: false
      t.text    :description
      t.boolean :active,      null: false, default: true
      t.timestamps
    end
    add_index :expense_categories, "business_id, lower(name)", unique: true,
              name: "index_expense_categories_on_business_id_and_lower_name"

    create_table :expense_types do |t|
      t.references :business,         null: false, foreign_key: true
      t.references :expense_category, null: false, foreign_key: true
      t.string  :name,        null: false
      t.text    :description
      t.boolean :active,      null: false, default: true
      t.timestamps
    end
    add_index :expense_types, "expense_category_id, lower(name)", unique: true,
              name: "index_expense_types_on_category_id_and_lower_name"

    create_table :expense_tags do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name,   null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :expense_tags, "business_id, lower(name)", unique: true,
              name: "index_expense_tags_on_business_id_and_lower_name"
  end
end
