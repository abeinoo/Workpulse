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
  # Idempotent / schema-history-tolerant: every remove_* is guarded by the
  # matching *_exists? check, and every add_* is guarded the same way, so
  # this migration is safe to run regardless of which of these FKs/indexes/
  # columns actually exist on a given database (e.g. a database whose
  # earlier migration history diverged and never created
  # source_pos_transaction_id's FK in the first place) — never assumes any
  # of them are present or absent.
  def up
    if foreign_key_exists?(:expenses, column: "source_pos_transaction_id")
      remove_foreign_key :expenses, column: "source_pos_transaction_id"
    end
    if index_exists?(:expenses, nil, name: "idx_expenses_on_source_pos_transaction_and_category")
      remove_index :expenses, name: "idx_expenses_on_source_pos_transaction_and_category"
    end
    if index_exists?(:expenses, nil, name: "index_expenses_on_source_pos_transaction_id")
      remove_index :expenses, name: "index_expenses_on_source_pos_transaction_id"
    end
    if column_exists?(:expenses, :source_pos_transaction_id)
      remove_column :expenses, :source_pos_transaction_id, :bigint
    end

    if foreign_key_exists?(:expenses, column: "source_pos_import_id")
      remove_foreign_key :expenses, column: "source_pos_import_id"
    end
    unless foreign_key_exists?(:expenses, :pos_imports, column: "source_pos_import_id")
      add_foreign_key :expenses, :pos_imports, column: "source_pos_import_id"
    end

    unless index_exists?(:expenses, [ :source_pos_import_id, :branch_id ], name: "idx_expenses_on_source_pos_import_and_branch")
      add_index :expenses, [ :source_pos_import_id, :branch_id ], unique: true,
                where: "source_pos_import_id IS NOT NULL",
                name: "idx_expenses_on_source_pos_import_and_branch"
    end
  end

  def down
    if index_exists?(:expenses, nil, name: "idx_expenses_on_source_pos_import_and_branch")
      remove_index :expenses, name: "idx_expenses_on_source_pos_import_and_branch"
    end

    if foreign_key_exists?(:expenses, column: "source_pos_import_id")
      remove_foreign_key :expenses, column: "source_pos_import_id"
    end
    unless foreign_key_exists?(:expenses, :sales_imports, column: "source_pos_import_id")
      add_foreign_key :expenses, :sales_imports, column: "source_pos_import_id"
    end

    unless column_exists?(:expenses, :source_pos_transaction_id)
      add_column :expenses, :source_pos_transaction_id, :bigint
    end
    unless index_exists?(:expenses, :source_pos_transaction_id, name: "index_expenses_on_source_pos_transaction_id")
      add_index :expenses, :source_pos_transaction_id, name: "index_expenses_on_source_pos_transaction_id"
    end
    unless index_exists?(:expenses, [ :source_pos_transaction_id, :expense_category_id ], name: "idx_expenses_on_source_pos_transaction_and_category")
      add_index :expenses, [ :source_pos_transaction_id, :expense_category_id ], unique: true,
                where: "source_pos_transaction_id IS NOT NULL",
                name: "idx_expenses_on_source_pos_transaction_and_category"
    end
    unless foreign_key_exists?(:expenses, :sales_transactions, column: "source_pos_transaction_id")
      add_foreign_key :expenses, :sales_transactions, column: "source_pos_transaction_id"
    end
  end
end
