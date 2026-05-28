class AddRuleProfileToShiftAssignments < ActiveRecord::Migration[8.1]
  def change
    add_reference :shift_assignments, :shift_rule_profile,
                  null: true, foreign_key: true
  end
end
