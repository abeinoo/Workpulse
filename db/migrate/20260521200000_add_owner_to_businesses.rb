class AddOwnerToBusinesses < ActiveRecord::Migration[8.1]
  def up
    add_reference :businesses, :owner, null: true, foreign_key: { to_table: :users }

    Business.find_each do |business|
      owner = business.users.where(is_super_admin: true).first
      business.update_column(:owner_id, owner.id) if owner
    end
  end

  def down
    remove_reference :businesses, :owner, foreign_key: { to_table: :users }
  end
end
