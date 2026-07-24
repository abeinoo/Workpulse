class BackfillDepositMatches < ActiveRecord::Migration[8.1]
  def up
    before_count = execute(
      "SELECT COUNT(*) FROM bank_statement_transactions WHERE matched_till_deposit_id IS NOT NULL"
    ).first["count"].to_i

    execute <<~SQL
      INSERT INTO deposit_matches
        (till_deposit_id, bank_statement_transaction_id, matched_amount, matched_by_id, matched_at, created_at, updated_at)
      SELECT matched_till_deposit_id, id, amount, matched_by_id,
             COALESCE(matched_at, updated_at), created_at, updated_at
      FROM bank_statement_transactions
      WHERE matched_till_deposit_id IS NOT NULL
    SQL

    after_count = execute("SELECT COUNT(*) FROM deposit_matches").first["count"].to_i
    raise ActiveRecord::IrreversibleMigration, "expected #{before_count} backfilled rows, got #{after_count}" if
      before_count != after_count
  end

  def down
    execute "DELETE FROM deposit_matches"
  end
end
