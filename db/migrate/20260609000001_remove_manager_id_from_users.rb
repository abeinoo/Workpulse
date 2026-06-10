# Phase 5 cleanup: direct employee→manager ownership (users.manager_id) is fully
# removed from runtime — management is inferred through Branch.branch_manager_id /
# area_manager_id and active ShiftAssignments. This drops the column, its index and
# the self-referential foreign key. Reversible.
#
# NOTE: not yet run. Apply with `bin/rails db:migrate` only after approval.
class RemoveManagerIdFromUsers < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :users, column: :manager_id
    remove_column :users, :manager_id  # drops index_users_on_manager_id with it
  end

  def down
    add_column :users, :manager_id, :integer
    add_index  :users, :manager_id
    add_foreign_key :users, :users, column: :manager_id, on_delete: :nullify
  end
end
