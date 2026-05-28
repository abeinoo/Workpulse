class CreateShiftTemplateEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :shift_template_entries do |t|
      t.references :shift_template, null: false, foreign_key: true
      t.references :shift,          null: false, foreign_key: true
      t.references :branch,         null: true,  foreign_key: true
      t.integer    :weekday,        null: false
      t.integer    :effective_from_offset, null: false, default: 0
      t.integer    :effective_to_offset
      t.string     :employee_role

      t.timestamps
    end

    add_index :shift_template_entries, :weekday
  end
end
