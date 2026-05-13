class CreateUserBranches < ActiveRecord::Migration[8.1]
  def change
    create_table :user_branches do |t|
      t.references :user,   null: false, foreign_key: true
      t.references :branch, null: false, foreign_key: true
      t.boolean :active,    null: false, default: true
      t.date    :joined_at
      t.timestamps
    end

    add_index :user_branches, [:user_id, :branch_id], unique: true
  end
end
