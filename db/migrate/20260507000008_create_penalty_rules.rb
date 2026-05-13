class CreatePenaltyRules < ActiveRecord::Migration[8.1]
  def change
    create_table :penalty_rules do |t|
      t.references :shift,         null: false, foreign_key: true
      t.string  :rule_type,        null: false
      t.integer :threshold_minutes, null: false
      t.string  :deduction_type,   null: false
      t.decimal :deduction_value,  precision: 10, scale: 2, null: false
      t.timestamps
    end

    add_index :penalty_rules, [ :shift_id, :rule_type, :threshold_minutes ], unique: true,
              name: "index_penalty_rules_on_shift_type_threshold"
  end
end
