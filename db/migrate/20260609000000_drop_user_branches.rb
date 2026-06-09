# Phase 5 cleanup: UserBranch is fully removed from runtime — branch membership is
# derived exclusively from active ShiftAssignments. This drops the now-unused
# join table. Reversible: #down recreates the table, indexes and foreign keys.
#
# NOTE: not yet run. Apply with `bin/rails db:migrate` only after approval.
class DropUserBranches < ActiveRecord::Migration[8.1]
  def up
    drop_table :user_branches
  end

  def down
    create_table :user_branches do |t|
      t.boolean  :active,    default: true, null: false
      t.integer  :branch_id, null: false
      t.date     :joined_at
      t.integer  :user_id,   null: false
      t.timestamps
    end
    add_index :user_branches, [ :user_id, :branch_id ], unique: true
    add_index :user_branches, :branch_id
    add_index :user_branches, :user_id
    add_foreign_key :user_branches, :users
    add_foreign_key :user_branches, :branches
  end
end
