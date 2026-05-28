class AddRuleProfileToShiftTemplateEntries < ActiveRecord::Migration[8.1]
  def change
    add_reference :shift_template_entries, :shift_rule_profile,
                  null: true, foreign_key: true
  end
end
