class AddDailyReconciliationIdToTillSessions < ActiveRecord::Migration[8.1]
  def up
    # ── 1. Add column as nullable ─────────────────────────────────────────────

    add_column :till_sessions, :daily_reconciliation_id, :bigint

    # ── 2. Backfill — invert the existing DR→session FK ──────────────────────
    #    daily_reconciliations.till_session_id is the current source of truth.

    execute <<~SQL
      UPDATE till_sessions ts
      SET daily_reconciliation_id = dr.id
      FROM daily_reconciliations dr
      WHERE dr.till_session_id = ts.id
    SQL

    # ── 3. Safety check ───────────────────────────────────────────────────────

    missing = execute(<<~SQL).first["count"].to_i
      SELECT COUNT(*) FROM till_sessions WHERE daily_reconciliation_id IS NULL
    SQL

    raise "Backfill incomplete: #{missing} till_sessions still missing daily_reconciliation_id" if missing > 0

    # ── 4. NOT NULL constraint ────────────────────────────────────────────────

    change_column_null :till_sessions, :daily_reconciliation_id, false

    # ── 5. Foreign key ────────────────────────────────────────────────────────

    add_foreign_key :till_sessions, :daily_reconciliations

    # ── 6. Unique index — enforces has_one from DR side ───────────────────────

    add_index :till_sessions, :daily_reconciliation_id,
              unique: true,
              name:   "idx_till_sessions_unique_dr"
  end

  def down
    remove_index  :till_sessions, name: "idx_till_sessions_unique_dr"
    remove_foreign_key :till_sessions, :daily_reconciliations
    remove_column :till_sessions, :daily_reconciliation_id
  end
end
