# Stock Transfer approval workflow (draft -> pending_approval -> approved |
# rejected | cancelled). A pending transfer reserves its source quantities —
# derived from this status, there is no reservation table
# (Inventory::StockAvailability).
#
# Every transfer that exists today was posted on creation (paired OUT/IN
# movements already written), so the backfill marks them all "approved".
# Their submitted/approved actor and time stay NULL: that is what identifies a
# legacy transfer posted on creation (StockTransfer#legacy_posting?). No
# movement, balance, item or audit row is read or written here.
class AddApprovalWorkflowToStockTransfers < ActiveRecord::Migration[8.1]
  STATUSES = %w[draft pending_approval approved rejected cancelled].freeze

  def up
    # Default "approved" fills every existing row in the same statement; the
    # default then becomes "draft" for new rows.
    add_column :stock_transfers, :status, :string, null: false, default: "approved"
    change_column_default :stock_transfers, :status, from: "approved", to: "draft"

    add_column :stock_transfers, :submitted_at, :datetime
    add_reference :stock_transfers, :submitted_by, foreign_key: { to_table: :users }, index: true
    add_column :stock_transfers, :approved_at, :datetime
    add_reference :stock_transfers, :approved_by,  foreign_key: { to_table: :users }, index: true
    add_column :stock_transfers, :rejected_at, :datetime
    add_reference :stock_transfers, :rejected_by,  foreign_key: { to_table: :users }, index: true
    add_column :stock_transfers, :rejection_reason, :text
    add_column :stock_transfers, :cancelled_at, :datetime
    add_reference :stock_transfers, :cancelled_by, foreign_key: { to_table: :users }, index: true
    add_column :stock_transfers, :cancellation_reason, :text

    add_index :stock_transfers, %i[business_id status]

    add_check_constraint :stock_transfers,
                         "status IN (#{STATUSES.map { |s| "'#{s}'" }.join(', ')})",
                         name: "stock_transfers_status_valid"
    add_check_constraint :stock_transfers,
                         "status <> 'rejected' OR (rejection_reason IS NOT NULL AND btrim(rejection_reason) <> '')",
                         name: "stock_transfers_rejection_reason_required"
    add_check_constraint :stock_transfers,
                         "status <> 'cancelled' OR (cancellation_reason IS NOT NULL AND btrim(cancellation_reason) <> '')",
                         name: "stock_transfers_cancellation_reason_required"
  end

  def down
    # Refuses to drop the workflow once a transfer exists that is not a plain
    # posted one: those rows (drafts, pending reservations, rejections,
    # cancellations) would silently turn into "posted" transfers without
    # movements.
    if select_value("SELECT 1 FROM stock_transfers WHERE status <> 'approved' LIMIT 1")
      raise ActiveRecord::IrreversibleMigration,
            "stock_transfers has non-approved rows; resolve them before rolling back the approval workflow"
    end

    remove_check_constraint :stock_transfers, name: "stock_transfers_cancellation_reason_required"
    remove_check_constraint :stock_transfers, name: "stock_transfers_rejection_reason_required"
    remove_check_constraint :stock_transfers, name: "stock_transfers_status_valid"
    remove_index :stock_transfers, %i[business_id status]

    remove_column :stock_transfers, :cancellation_reason
    remove_reference :stock_transfers, :cancelled_by, foreign_key: { to_table: :users }, index: true
    remove_column :stock_transfers, :cancelled_at
    remove_column :stock_transfers, :rejection_reason
    remove_reference :stock_transfers, :rejected_by, foreign_key: { to_table: :users }, index: true
    remove_column :stock_transfers, :rejected_at
    remove_reference :stock_transfers, :approved_by, foreign_key: { to_table: :users }, index: true
    remove_column :stock_transfers, :approved_at
    remove_reference :stock_transfers, :submitted_by, foreign_key: { to_table: :users }, index: true
    remove_column :stock_transfers, :submitted_at
    remove_column :stock_transfers, :status
  end
end
