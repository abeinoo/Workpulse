class AddRejectionAndInitiatorToDepositResponsibilityTransfers < ActiveRecord::Migration[8.0]
  # A DepositResponsibilityTransfer is now requested either at Day Close (the
  # closing cashier names someone) or later by a manager from the DR page, and
  # ends Accepted, Rejected (by its recipient) or Cancelled.
  #
  #   initiated_by — who requested it when that isn't from_user (a manager);
  #                  NULL means from_user requested it (Day Close, legacy rows).
  #   notes        — the requester's optional note.
  #   accepted_by  — who accepted (the recipient, or the business owner under
  #                  the existing owner-may-accept rule); NULL on legacy rows.
  #   rejected_*   — the recipient's rejection and its reason.
  #
  # "Pending" gains rejected_at IS NULL, so the one-pending-per-DR partial
  # unique index is rebuilt to match — otherwise a rejected transfer would
  # still block the next request. All additive; no existing row changes.
  def up
    add_reference :deposit_responsibility_transfers, :initiated_by, foreign_key: { to_table: :users }
    add_reference :deposit_responsibility_transfers, :accepted_by,  foreign_key: { to_table: :users }
    add_reference :deposit_responsibility_transfers, :rejected_by,  foreign_key: { to_table: :users }
    add_column    :deposit_responsibility_transfers, :rejected_at,      :datetime
    add_column    :deposit_responsibility_transfers, :rejection_reason, :text
    add_column    :deposit_responsibility_transfers, :notes,            :text

    remove_index :deposit_responsibility_transfers, name: "idx_drt_one_pending_per_dr"
    add_index    :deposit_responsibility_transfers, :daily_reconciliation_id,
                 unique: true, name: "idx_drt_one_pending_per_dr",
                 where: "accepted_at IS NULL AND cancelled_at IS NULL AND rejected_at IS NULL"
  end

  def down
    remove_index :deposit_responsibility_transfers, name: "idx_drt_one_pending_per_dr"
    add_index    :deposit_responsibility_transfers, :daily_reconciliation_id,
                 unique: true, name: "idx_drt_one_pending_per_dr",
                 where: "accepted_at IS NULL AND cancelled_at IS NULL"

    remove_column    :deposit_responsibility_transfers, :notes
    remove_column    :deposit_responsibility_transfers, :rejection_reason
    remove_column    :deposit_responsibility_transfers, :rejected_at
    remove_reference :deposit_responsibility_transfers, :rejected_by,  foreign_key: { to_table: :users }
    remove_reference :deposit_responsibility_transfers, :accepted_by,  foreign_key: { to_table: :users }
    remove_reference :deposit_responsibility_transfers, :initiated_by, foreign_key: { to_table: :users }
  end
end
