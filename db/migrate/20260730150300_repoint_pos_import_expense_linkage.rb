class RepointPosImportExpenseLinkage < ActiveRecord::Migration[8.1]
  # expenses.source_pos_import_id / source_pos_transaction_id are leftovers from
  # an earlier, abandoned attempt at this same feature (FK'd to sales_imports/
  # sales_transactions after this session's unrelated POS->Sales rename).
  # Verified 100% NULL across all existing expenses before writing this.
  #
  # source_pos_import_id is repointed to the new pos_imports table and reused
  # by Finance::PosImports::ExpenseGenerator. source_pos_transaction_id encoded
  # an abandoned one-expense-per-transaction design (this feature creates one
  # aggregate expense per branch instead) and is dropped along with its index.
  def up
    remove_foreign_key :expenses, column: "source_pos_transaction_id"
    remove_index  :expenses, name: "idx_expenses_on_source_pos_transaction_and_category"
    remove_index  :expenses, name: "index_expenses_on_source_pos_transaction_id"
    remove_column :expenses, :source_pos_transaction_id, :bigint

    remove_foreign_key :expenses, column: "source_pos_import_id"
    add_foreign_key :expenses, :pos_imports, column: "source_pos_import_id"

    add_index :expenses, [ :source_pos_import_id, :branch_id ], unique: true,
              where: "source_pos_import_id IS NOT NULL",
              name: "idx_expenses_on_source_pos_import_and_branch"
  end

  def down
    remove_index :expenses, name: "idx_expenses_on_source_pos_import_and_branch"

    remove_foreign_key :expenses, column: "source_pos_import_id"
    add_foreign_key :expenses, :sales_imports, column: "source_pos_import_id"

    add_column :expenses, :source_pos_transaction_id, :bigint
    add_index  :expenses, :source_pos_transaction_id, name: "index_expenses_on_source_pos_transaction_id"
    add_index  :expenses, [ :source_pos_transaction_id, :expense_category_id ], unique: true,
               where: "source_pos_transaction_id IS NOT NULL",
               name: "idx_expenses_on_source_pos_transaction_and_category"
    add_foreign_key :expenses, :sales_transactions, column: "source_pos_transaction_id"
  end
end
