class AddSettleRemainingBalancePermission < ActiveRecord::Migration[8.0]
  def up
    PermissionRole.find_each do |role|
      next unless role.permissions.include?("void_till_deposit")

      role.permissions |= ["settle_remaining_deposit_balance"]
      role.save!(validate: false)
    end
  end

  def down
    PermissionRole.find_each do |role|
      role.permissions -= ["settle_remaining_deposit_balance"]
      role.save!(validate: false)
    end
  end
end
