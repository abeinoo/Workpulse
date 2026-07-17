class AddConfirmGoodsReceiptsPermission < ActiveRecord::Migration[8.1]
  # Confirming a goods receipt (posting stock + deducting custody) is now gated
  # separately from creating one. Backfill any role that could already post
  # receipts under the old atomic create flow, so existing behavior is preserved.
  def up
    PermissionRole.find_each do |role|
      existing = Array(role.permissions)
      next unless (existing & %w[manage_stock_receipts manage_inventory]).any?
      next if existing.include?("confirm_goods_receipts")

      role.update_columns(permissions: existing + %w[confirm_goods_receipts])
      say "Added confirm_goods_receipts to '#{role.name}' (id=#{role.id})"
    end
  end

  def down
    PermissionRole.find_each do |role|
      existing = Array(role.permissions)
      next unless existing.include?("confirm_goods_receipts")

      role.update_columns(permissions: existing - %w[confirm_goods_receipts])
    end
  end
end
