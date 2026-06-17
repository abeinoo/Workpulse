class RedesignExpenseBalanceModel < ActiveRecord::Migration[8.1]
  def up
    # 1. Migrate any 'paid' expenses to 'approved' before dropping the status value
    execute "UPDATE expenses SET status = 'approved' WHERE status = 'paid'"

    # 2. Drop payment-lifecycle columns from expenses
    remove_index :expenses, name: "index_expenses_on_business_id_and_payment_type", if_exists: true
    remove_index :expenses, name: "index_expenses_on_custody_account_id",           if_exists: true
    remove_index :expenses, name: "index_expenses_on_paid_by_id",                   if_exists: true

    remove_column :expenses, :payment_type,       :string
    remove_column :expenses, :custody_account_id, :bigint
    remove_column :expenses, :paid_by_id,         :bigint
    remove_column :expenses, :paid_at,            :datetime
    remove_column :expenses, :vendor_name,        :string
    remove_column :expenses, :vendor_reference,   :string

    # 3. Rename custody transaction types to new vocabulary
    execute "UPDATE custody_transactions SET txn_type = 'top_up'            WHERE txn_type = 'funding'"
    execute "UPDATE custody_transactions SET txn_type = 'expense_deduction' WHERE txn_type = 'expense'"

    # 4. Remove 'returned' transactions (only ever posted by settlement approval)
    #    Nullify expense link on any that somehow reference one, then delete.
    execute "DELETE FROM custody_transactions WHERE txn_type = 'returned'"

    # 5. Drop custody_settlements and its FK on custody_transactions
    remove_index  :custody_transactions, name: "index_custody_transactions_on_custody_settlement_id", if_exists: true
    remove_column :custody_transactions, :custody_settlement_id, :bigint

    # Drop index used by txn_type queries (recreated below with new values)
    remove_index :custody_transactions, name: "index_custody_transactions_on_business_id_and_txn_type", if_exists: true
    add_index :custody_transactions, [ :business_id, :txn_type ], name: "index_custody_transactions_on_business_id_and_txn_type"

    drop_table :custody_settlements
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
