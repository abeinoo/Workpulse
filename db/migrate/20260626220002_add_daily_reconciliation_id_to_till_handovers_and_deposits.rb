class AddDailyReconciliationIdToTillHandoversAndDeposits < ActiveRecord::Migration[8.1]
  def up
    # ════════════════════════════════════════════════════════════════════
    # TILL HANDOVERS
    # ════════════════════════════════════════════════════════════════════

    # ── 1. Add column ────────────────────────────────────────────────────

    add_column :till_handovers, :daily_reconciliation_id, :bigint

    # ── 2. Backfill via till_session_id → daily_reconciliations ─────────

    execute <<~SQL
      UPDATE till_handovers th
      SET daily_reconciliation_id = dr.id
      FROM daily_reconciliations dr
      WHERE dr.till_session_id = th.till_session_id
    SQL

    # ── 3. Safety check ──────────────────────────────────────────────────

    missing = execute(<<~SQL).first["count"].to_i
      SELECT COUNT(*) FROM till_handovers WHERE daily_reconciliation_id IS NULL
    SQL

    raise "Backfill incomplete: #{missing} till_handovers still missing daily_reconciliation_id" if missing > 0

    # ── 4. NOT NULL + FK + index ─────────────────────────────────────────

    change_column_null :till_handovers, :daily_reconciliation_id, false
    add_foreign_key    :till_handovers, :daily_reconciliations
    add_index          :till_handovers, :daily_reconciliation_id,
                       name: "index_till_handovers_on_dr_id"

    # ════════════════════════════════════════════════════════════════════
    # TILL DEPOSITS
    # ════════════════════════════════════════════════════════════════════

    # ── 1. Add column ────────────────────────────────────────────────────

    add_column :till_deposits, :daily_reconciliation_id, :bigint

    # ── 2. Backfill via till_session_id → daily_reconciliations ─────────

    execute <<~SQL
      UPDATE till_deposits td
      SET daily_reconciliation_id = dr.id
      FROM daily_reconciliations dr
      WHERE dr.till_session_id = td.till_session_id
    SQL

    # ── 3. Safety check ──────────────────────────────────────────────────

    missing = execute(<<~SQL).first["count"].to_i
      SELECT COUNT(*) FROM till_deposits WHERE daily_reconciliation_id IS NULL
    SQL

    raise "Backfill incomplete: #{missing} till_deposits still missing daily_reconciliation_id" if missing > 0

    # ── 4. NOT NULL + FK + index ─────────────────────────────────────────

    change_column_null :till_deposits, :daily_reconciliation_id, false
    add_foreign_key    :till_deposits, :daily_reconciliations
    add_index          :till_deposits, :daily_reconciliation_id,
                       name: "index_till_deposits_on_dr_id"
  end

  def down
    remove_index  :till_deposits, name: "index_till_deposits_on_dr_id"
    remove_foreign_key :till_deposits, :daily_reconciliations
    remove_column :till_deposits, :daily_reconciliation_id

    remove_index  :till_handovers, name: "index_till_handovers_on_dr_id"
    remove_foreign_key :till_handovers, :daily_reconciliations
    remove_column :till_handovers, :daily_reconciliation_id
  end
end
