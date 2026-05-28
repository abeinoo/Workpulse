class CreateShiftTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :shift_templates do |t|
      t.references :business,   null: false, foreign_key: true
      t.string     :name,       null: false
      t.text       :description
      t.boolean    :active,     null: false, default: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.datetime   :archived_at

      t.timestamps
    end

    add_index :shift_templates, [ :business_id, :name ], unique: true
  end
end
