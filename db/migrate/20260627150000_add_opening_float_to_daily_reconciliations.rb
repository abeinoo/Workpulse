class AddOpeningFloatToDailyReconciliations < ActiveRecord::Migration[8.0]
  def change
    add_reference :daily_reconciliations, :opening_float_source_handover,
                  null:        true,
                  foreign_key: { to_table: :till_handovers },
                  index:       { name: "index_dr_on_opening_float_source_handover_id" }

    # One waiting_for_opening DR per branch at a time — mirrors the existing
    # idx_dr_one_open_per_branch partial unique index.
    add_index :daily_reconciliations, :branch_id,
              unique: true,
              where:  "(state = 'waiting_for_opening')",
              name:   "idx_dr_one_waiting_per_branch"
  end
end
