class CreateSalaryProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :salary_profiles do |t|
      t.references :user, null: false, foreign_key: true
      t.string  :salary_type,   null: false
      t.decimal :base_amount,   precision: 12, scale: 2, null: false
      t.string  :currency,      null: false, default: "SAR"
      t.date    :effective_from, null: false
      t.boolean :active,        null: false, default: true
      t.timestamps
    end

    add_index :salary_profiles, [:user_id, :active]
  end
end
