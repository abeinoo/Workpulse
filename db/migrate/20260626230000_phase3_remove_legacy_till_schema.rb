class Phase3RemoveLegacyTillSchema < ActiveRecord::Migration[8.1]
  def up
    # ── 1. daily_reconciliations.till_session_id ─────────────────────────────
    # The old reverse FK direction (DR pointed to TS). Now TS points to DR.
    remove_foreign_key :daily_reconciliations, column: :till_session_id
    remove_index       :daily_reconciliations, name: "idx_daily_reconciliations_unique_session"
    remove_column      :daily_reconciliations, :till_session_id

    # ── 2. till_handovers.till_session_id ────────────────────────────────────
    # Handovers are now owned by DailyReconciliation, not TillSession.
    remove_foreign_key :till_handovers, column: :till_session_id
    remove_column      :till_handovers, :till_session_id

    # ── 3. till_deposits.till_session_id ─────────────────────────────────────
    # Deposits are now owned by DailyReconciliation, not TillSession.
    remove_foreign_key :till_deposits, column: :till_session_id
    remove_column      :till_deposits, :till_session_id

    # ── 4. till_sessions — remove columns that moved to DailyReconciliation ──
    # Drop the partial index first (it references both branch_id and state).
    remove_index :till_sessions, name: "idx_till_sessions_one_open_per_branch"

    # branch_id: remove FK, then column (PG drops simple index automatically).
    remove_foreign_key :till_sessions, column: :branch_id
    remove_column      :till_sessions, :branch_id

    # business_id: same pattern.
    remove_foreign_key :till_sessions, column: :business_id
    remove_column      :till_sessions, :business_id

    # Remaining columns with no FK constraints.
    remove_column :till_sessions, :state
    remove_column :till_sessions, :fresha_date
    remove_column :till_sessions, :opened_at
    remove_column :till_sessions, :closed_at
    remove_column :till_sessions, :deposited_at
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Phase 3 legacy column removal cannot be auto-reversed. " \
          "Restore from a pre-Phase-3 database snapshot if needed."
  end
end
