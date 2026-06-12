class CreateDepartmentsAndAddToUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :departments do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name,   null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    # Case-insensitive uniqueness per business — prevents "Reception" vs
    # "reception" duplicates. Paired with the model-level normalization that
    # trims/collapses whitespace before save.
    add_index :departments, "business_id, lower((name)::text)",
              name: "index_departments_on_business_id_and_lower_name",
              unique: true

    # Additive only: the existing free-text users.department column is kept
    # intact for backward compatibility. New features read department_id.
    add_reference :users, :department, null: true, foreign_key: true, index: true
  end
end
