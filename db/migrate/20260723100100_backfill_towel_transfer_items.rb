class BackfillTowelTransferItems < ActiveRecord::Migration[8.1]
  def up
    before_count = execute("SELECT COUNT(*) FROM towel_transfers").first["count"].to_i

    execute <<~SQL
      INSERT INTO towel_transfer_items
        (towel_transfer_id, towel_type_id, declared_quantity, confirmed_quantity, created_at, updated_at)
      SELECT id, towel_type_id, declared_quantity, confirmed_quantity, created_at, updated_at
      FROM towel_transfers
    SQL

    after_count = execute("SELECT COUNT(*) FROM towel_transfer_items").first["count"].to_i
    raise ActiveRecord::IrreversibleMigration, "expected #{before_count} backfilled rows, got #{after_count}" if
      before_count != after_count
  end

  def down
    execute "DELETE FROM towel_transfer_items"
  end
end
