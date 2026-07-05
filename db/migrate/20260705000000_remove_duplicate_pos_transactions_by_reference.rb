class RemoveDuplicatePosTransactionsByReference < ActiveRecord::Migration[8.0]
  # Removes duplicate pos_transaction rows that share the same
  # (business_id, reference_number), keeping only the oldest record (lowest id)
  # in each group. Runs before the partial unique index is added.
  #
  # Safe to re-run: when no duplicates exist the count query returns 0 and the
  # DELETE touches nothing.
  def up
    duplicate_count = select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM pos_transactions
      WHERE reference_number IS NOT NULL
        AND id NOT IN (
          SELECT MIN(id)
          FROM   pos_transactions
          WHERE  reference_number IS NOT NULL
          GROUP  BY business_id, reference_number
        )
    SQL

    if duplicate_count.zero?
      say "pos_transactions: no duplicate (business_id, reference_number) rows found — nothing to remove."
      return
    end

    say "pos_transactions: removing #{duplicate_count} duplicate row(s), keeping lowest id per (business_id, reference_number)..."

    execute(<<~SQL)
      DELETE FROM pos_transactions
      WHERE reference_number IS NOT NULL
        AND id NOT IN (
          SELECT MIN(id)
          FROM   pos_transactions
          WHERE  reference_number IS NOT NULL
          GROUP  BY business_id, reference_number
        )
    SQL

    say "pos_transactions: removed #{duplicate_count} duplicate row(s). Oldest record preserved per group."
  end

  def down
    say "pos_transactions: data migration — deleted duplicates cannot be restored."
  end
end
