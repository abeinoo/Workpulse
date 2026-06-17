class FinalizeEmployeeBalanceModel < ActiveRecord::Migration[8.1]
  def change
    # ── 1. One balance account per employee ──────────────────────────────
    # Pre-production only: deduplicate by keeping the account with the
    # highest absolute balance per (business_id, user_id) pair, deleting
    # the rest (transactions cascade via restrict — reassign first).
    execute <<~SQL
      WITH ranked AS (
        SELECT id,
               ROW_NUMBER() OVER (
                 PARTITION BY business_id, user_id
                 ORDER BY ABS(current_balance) DESC, id ASC
               ) AS rn
        FROM custody_accounts
      ),
      to_delete AS (SELECT id FROM ranked WHERE rn > 1)
      DELETE FROM custody_transactions
      WHERE custody_account_id IN (SELECT id FROM to_delete);
    SQL
    execute <<~SQL
      DELETE FROM custody_accounts
      WHERE id IN (
        SELECT id FROM (
          SELECT id,
                 ROW_NUMBER() OVER (
                   PARTITION BY business_id, user_id
                   ORDER BY ABS(current_balance) DESC, id ASC
                 ) AS rn
          FROM custody_accounts
        ) ranked WHERE rn > 1
      );
    SQL

    # Drop the old (business_id, user_id, name) composite unique — replace
    # with a strict (business_id, user_id) unique so no employee can have
    # more than one balance account regardless of name.
    remove_index :custody_accounts,
                 name: "index_custody_accounts_on_business_user_and_name",
                 if_exists: true

    add_index :custody_accounts, [ :business_id, :user_id ],
              unique: true,
              name: "index_custody_accounts_on_business_id_and_user_id"

    # ── 2. Drop vendor_name from recurring_expenses ───────────────────────
    remove_column :recurring_expenses, :vendor_name, :string
    remove_column :recurring_expenses, :description, :text

    # ── 3. Balance Top-Up Requests ────────────────────────────────────────
    create_table :balance_requests do |t|
      t.references :business,    null: false, foreign_key: true
      t.references :created_by,  null: false, foreign_key: { to_table: :users }
      t.references :branch,                   foreign_key: true
      t.references :approved_by,              foreign_key: { to_table: :users }
      t.references :paid_by,                  foreign_key: { to_table: :users }

      t.decimal  :amount,           precision: 12, scale: 2, null: false
      t.date     :request_date,     null: false
      t.text     :notes,            null: false
      t.string   :status,           null: false, default: "draft"
      t.string   :reference_number
      t.text     :rejection_reason
      t.datetime :approved_at
      t.datetime :paid_at

      t.timestamps
    end

    add_index :balance_requests, [ :business_id, :status ]
    add_index :balance_requests, :reference_number, unique: true, where: "reference_number IS NOT NULL"
  end
end
