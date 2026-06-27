class BackfillMissingDailyReconciliations < ActiveRecord::Migration[8.1]
  # Root cause: RestructureDailyReconciliations dropped and recreated the
  # daily_reconciliations table with a new till_session_id FK. Any TillSession
  # that existed before that migration (or was created while the after_create_commit
  # callback silently failed) has no corresponding DailyReconciliation.
  #
  # This migration creates the missing records atomically. It is safe to run
  # multiple times — the LEFT JOIN / WHERE dr.id IS NULL is idempotent.
  def up
    execute <<~SQL
      INSERT INTO daily_reconciliations (till_session_id, created_at, updated_at)
      SELECT ts.id, NOW(), NOW()
      FROM till_sessions ts
      LEFT JOIN daily_reconciliations dr ON dr.till_session_id = ts.id
      WHERE dr.id IS NULL
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Cannot safely remove backfilled reconciliations — they may have audit history."
  end
end
