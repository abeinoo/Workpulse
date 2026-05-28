class AddSourceTemplateToShiftAssignments < ActiveRecord::Migration[8.1]
  def change
    add_reference :shift_assignments, :source_template,
                  foreign_key: { to_table: :shift_templates },
                  null: true,
                  index: true
  end
end
