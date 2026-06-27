class AddAccountingFieldsToDailyReconciliations < ActiveRecord::Migration[8.1]
  def up
    # ── 1. Add columns as nullable first so backfill can run before constraints ──

    add_column :daily_reconciliations, :branch_id,     :bigint
    add_column :daily_reconciliations, :business_id,   :bigint
    add_column :daily_reconciliations, :business_date, :date          # accounting date (fresha_date)
    add_column :daily_reconciliations, :state,         :string, default: "open"
    add_column :daily_reconciliations, :opened_at,     :datetime
    add_column :daily_reconciliations, :closed_at,     :datetime
    add_column :daily_reconciliations, :deposited_at,  :datetime

    # ── 2. Backfill from till_sessions via the existing till_session_id FK ──────

    execute <<~SQL
      UPDATE daily_reconciliations dr
      SET
        branch_id     = ts.branch_id,
        business_id   = ts.business_id,
        business_date = ts.fresha_date,
        state         = ts.state,
        opened_at     = ts.opened_at,
        closed_at     = ts.closed_at,
        deposited_at  = ts.deposited_at
      FROM till_sessions ts
      WHERE ts.id = dr.till_session_id
    SQL

    # ── 3. Safety check — reject partial backfills ────────────────────────────

    missing = execute(<<~SQL).first["count"].to_i
      SELECT COUNT(*) FROM daily_reconciliations
      WHERE branch_id IS NULL OR business_id IS NULL OR state IS NULL OR opened_at IS NULL
    SQL

    raise "Backfill incomplete: #{missing} daily_reconciliations still missing required fields" if missing > 0

    # ── 4. Apply NOT NULL constraints where data guarantees allow it ──────────
    #    business_date and closed_at/deposited_at remain nullable (open sessions
    #    have no fresha_date/closed_at/deposited_at until the day closes).

    change_column_null :daily_reconciliations, :branch_id,   false
    change_column_null :daily_reconciliations, :business_id, false
    change_column_null :daily_reconciliations, :state,       false
    change_column_null :daily_reconciliations, :opened_at,   false

    # ── 5. Foreign keys ───────────────────────────────────────────────────────

    add_foreign_key :daily_reconciliations, :branches
    add_foreign_key :daily_reconciliations, :businesses

    # ── 6. Indexes ────────────────────────────────────────────────────────────

    add_index :daily_reconciliations, :branch_id,   name: "index_dr_on_branch_id"
    add_index :daily_reconciliations, :business_id, name: "index_dr_on_business_id"

    # Enforce: at most one open reconciliation per branch at any time.
    # Mirrors idx_till_sessions_one_open_per_branch on the session side
    # and will replace it once TillSession.state is removed.
    add_index :daily_reconciliations, :branch_id,
              unique: true,
              where:  "state = 'open'",
              name:   "idx_dr_one_open_per_branch"
  end

  def down
    remove_index  :daily_reconciliations, name: "idx_dr_one_open_per_branch"
    remove_index  :daily_reconciliations, name: "index_dr_on_business_id"
    remove_index  :daily_reconciliations, name: "index_dr_on_branch_id"

    remove_foreign_key :daily_reconciliations, :businesses
    remove_foreign_key :daily_reconciliations, :branches

    remove_column :daily_reconciliations, :deposited_at
    remove_column :daily_reconciliations, :closed_at
    remove_column :daily_reconciliations, :opened_at
    remove_column :daily_reconciliations, :state
    remove_column :daily_reconciliations, :business_date
    remove_column :daily_reconciliations, :business_id
    remove_column :daily_reconciliations, :branch_id
  end
end
