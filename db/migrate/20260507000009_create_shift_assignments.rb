class CreateShiftAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :shift_assignments do |t|
      t.references :user,           null: false, foreign_key: true
      t.references :shift,          null: false, foreign_key: true
      t.references :branch,         null: false, foreign_key: true
      t.date :effective_from,       null: false
      t.date :effective_to
      t.timestamps
    end

    # Fast lookup: "what's the active assignment for this user in this branch?"
    add_index :shift_assignments, [ :user_id, :branch_id ]
    add_index :shift_assignments, [ :user_id, :effective_from ]
  end
end
