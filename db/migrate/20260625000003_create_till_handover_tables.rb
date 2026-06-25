class CreateTillHandoverTables < ActiveRecord::Migration[8.1]
  def change
    # ── till_handovers ────────────────────────────────────────────────────
    # Each row is one link in the day's chain of till custody.
    # Chain integrity is enforced by two partial unique indexes (see below).
    create_table :till_handovers do |t|
      t.references :business,    null: false, foreign_key: true
      t.references :branch,      null: false, foreign_key: true
      t.date       :business_date, null: false

      # Who handed over and who received.
      # to_user is NULL when handover_type = 'depositor' (no recipient).
      t.references :from_user,   null: false, foreign_key: { to_table: :users }
      t.references :to_user,     null: true,  foreign_key: { to_table: :users }

      # 'transfer' | 'depositor'
      t.string :handover_type, null: false

      # Self-referential: points to the handover this one follows.
      # NULL = first handover of the day for this branch.
      t.bigint :previous_handover_id

      # NULL = pending (transfer awaiting acceptance).
      # Set at acceptance time for transfers; set at creation for depositor.
      t.datetime :accepted_at

      t.text :notes

      t.timestamps
    end

    add_foreign_key :till_handovers, :till_handovers,
                    column: :previous_handover_id

    # Enforce: only one successor per link in the chain.
    add_index :till_handovers, :previous_handover_id,
              unique: true,
              where: "previous_handover_id IS NOT NULL",
              name: "idx_till_handovers_unique_successor"

    # Enforce: only one chain head (root) per branch per day.
    add_index :till_handovers, %i[branch_id business_date],
              unique: true,
              where: "previous_handover_id IS NULL",
              name: "idx_till_handovers_unique_chain_head"

    # Fast lookup: all handovers for a branch on a given date.
    add_index :till_handovers, %i[branch_id business_date],
              name: "idx_till_handovers_branch_date"

    # Fast lookup: handovers involving a specific user.
    add_index :till_handovers, %i[from_user_id business_date],
              name: "idx_till_handovers_from_user_date"

    # ── till_handover_lines ───────────────────────────────────────────────
    # One row per payment method per handover — the reported amounts.
    # Net = collected_amount - refund_amount (never stored).
    create_table :till_handover_lines do |t|
      t.references :till_handover,  null: false, foreign_key: true
      t.references :payment_method, null: false, foreign_key: true

      t.decimal :collected_amount, null: false, default: 0,
                                   precision: 12, scale: 2
      t.decimal :refund_amount,    null: false, default: 0,
                                   precision: 12, scale: 2

      t.timestamps
    end

    # One line per method per handover.
    add_index :till_handover_lines, %i[till_handover_id payment_method_id],
              unique: true,
              name: "idx_till_handover_lines_unique_method"

    # ── till_deposits ─────────────────────────────────────────────────────
    # Cash deposits made by the final till holder (depositor-type handover).
    # Only cash-like payment methods appear here.
    create_table :till_deposits do |t|
      t.references :till_handover,  null: false, foreign_key: true
      t.references :payment_method, null: false, foreign_key: true
      t.references :deposited_by,   null: false,
                                    foreign_key: { to_table: :users }

      t.decimal  :amount,       null: false, precision: 12, scale: 2
      t.datetime :deposited_at, null: false
      t.string   :reference     # ATM / bank slip reference
      t.text     :notes

      # Voidable (mirrors the concern columns)
      t.datetime   :voided_at
      t.references :voided_by,  null: true, foreign_key: { to_table: :users }
      t.string     :void_reason

      t.timestamps
    end

    add_index :till_deposits, %i[till_handover_id payment_method_id],
              name: "idx_till_deposits_handover_method"

    # ── daily_reconciliations ─────────────────────────────────────────────
    # Thin management record: just tracks who verified and when.
    # All financial figures are computed at query time from the handover chain.
    create_table :daily_reconciliations do |t|
      t.references :business,     null: false, foreign_key: true
      t.references :branch,       null: false, foreign_key: true
      t.date       :business_date, null: false

      t.references :verified_by,  null: true,
                                  foreign_key: { to_table: :users }
      t.datetime   :verified_at
      t.text       :notes

      t.timestamps
    end

    # One reconciliation record per branch per day.
    add_index :daily_reconciliations, %i[branch_id business_date],
              unique: true,
              name: "idx_daily_reconciliations_unique_per_branch_day"
  end
end
