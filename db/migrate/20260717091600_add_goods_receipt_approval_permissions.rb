class AddGoodsReceiptApprovalPermissions < ActiveRecord::Migration[8.1]
  # GoodsReceiptPolicy#create?/#void? no longer accept manage_stock_receipts —
  # replaced by dedicated create_goods_receipts/void_goods_receipts permissions
  # (mirrors the earlier confirm_goods_receipts split). Backfill both onto any
  # role that already had manage_stock_receipts, preserving existing behavior.
  # approve_goods_receipts is a brand-new capability — no backfill, nobody
  # should silently inherit approval authority.
  def up
    PermissionRole.find_each do |role|
      existing = Array(role.permissions)
      next unless existing.include?("manage_stock_receipts")

      additions = %w[create_goods_receipts void_goods_receipts] - existing
      next if additions.empty?

      role.update_columns(permissions: existing + additions)
      say "Added #{additions.join(', ')} to '#{role.name}' (id=#{role.id})"
    end
  end

  def down
    PermissionRole.find_each do |role|
      existing = Array(role.permissions)
      removed = existing & %w[create_goods_receipts void_goods_receipts]
      next if removed.empty?

      role.update_columns(permissions: existing - removed)
    end
  end
end
