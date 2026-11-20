# Product availability per warehouse — Phase 1, unit 1 (additive only).
#
# A product_warehouse_settings row now records an explicit availability state:
#   no row               -> Not Configured (unchanged; nothing is created here)
#   status = "active"    -> Active
#   status = "inactive"  -> Inactive (settings kept for reactivation)
#
# Every EXISTING row becomes "active" with per-warehouse notifications on
# (decision N1 for central rows; decision D1, 2026-11-19: rows users created
# explicitly in BRANCH warehouses start Active too). No row is created for any
# other product/warehouse pair, no threshold or reorder value is changed,
# and products' legacy columns are not read or written. business_id is
# derived from each row's product (tenancy convention; no behaviour effect).
#
# down refuses once an inactive row exists: dropping the status column would
# silently turn deactivated pairs back into monitored ones.
class AddAvailabilityToProductWarehouseSettings < ActiveRecord::Migration[8.1]
  TABLE = :product_warehouse_settings

  def up
    negative = select_value("SELECT COUNT(*) FROM product_warehouse_settings WHERE low_stock_level < 0 OR reorder_quantity < 0").to_i
    raise "#{negative} product_warehouse_settings row(s) hold a negative quantity; resolve them before this migration" if negative.positive?

    add_column TABLE, :status, :string, null: false, default: "active"
    add_column TABLE, :receive_low_stock_notification, :boolean, null: false, default: true

    add_reference TABLE, :business, foreign_key: true, null: true, index: false
    execute <<~SQL
      UPDATE product_warehouse_settings s
      SET business_id = p.business_id
      FROM products p
      WHERE p.id = s.product_id
    SQL
    change_column_null TABLE, :business_id, false
    add_index TABLE, %i[business_id warehouse_id status], name: "index_pws_on_business_warehouse_status"

    add_column TABLE, :status_changed_at, :datetime
    add_reference TABLE, :status_changed_by, foreign_key: { to_table: :users }, index: false
    add_column TABLE, :status_reason, :text
    add_reference TABLE, :created_by, foreign_key: { to_table: :users }, index: false
    add_reference TABLE, :updated_by, foreign_key: { to_table: :users }, index: false

    add_check_constraint TABLE, "status IN ('active', 'inactive')", name: "pws_status_known"
    add_check_constraint TABLE, "low_stock_level >= 0 AND reorder_quantity >= 0", name: "pws_quantities_non_negative"
    add_check_constraint TABLE, "status = 'active' OR (status_reason IS NOT NULL AND status_changed_at IS NOT NULL)",
                         name: "pws_inactive_has_reason"
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM product_warehouse_settings WHERE status = 'inactive')")
      raise ActiveRecord::IrreversibleMigration,
            "inactive product availability rows exist; rolling back would turn them back into monitored pairs"
    end

    remove_check_constraint TABLE, name: "pws_inactive_has_reason"
    remove_check_constraint TABLE, name: "pws_quantities_non_negative"
    remove_check_constraint TABLE, name: "pws_status_known"
    remove_reference TABLE, :updated_by, foreign_key: { to_table: :users }, index: false
    remove_reference TABLE, :created_by, foreign_key: { to_table: :users }, index: false
    remove_column TABLE, :status_reason
    remove_reference TABLE, :status_changed_by, foreign_key: { to_table: :users }, index: false
    remove_column TABLE, :status_changed_at
    remove_index TABLE, name: "index_pws_on_business_warehouse_status"
    remove_reference TABLE, :business, foreign_key: true, index: false
    remove_column TABLE, :receive_low_stock_notification
    remove_column TABLE, :status
  end
end
