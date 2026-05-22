class CreatePermissionRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :permission_roles do |t|
      t.string  :name,           null: false
      t.text    :description
      t.integer :business_id,    null: false
      t.jsonb   :permissions,    null: false, default: []
      t.boolean :system_default, null: false, default: false

      t.timestamps
    end

    add_index :permission_roles, :business_id
    add_index :permission_roles, [ :business_id, :name ], unique: true

    add_foreign_key :permission_roles, :businesses
  end
end
