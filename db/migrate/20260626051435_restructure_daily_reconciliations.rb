class RestructureDailyReconciliations < ActiveRecord::Migration[8.1]
  def up
    remove_index  :daily_reconciliations, name: "idx_daily_reconciliations_unique_per_branch_day"
    remove_index  :daily_reconciliations, name: "index_daily_reconciliations_on_branch_id"
    remove_index  :daily_reconciliations, name: "index_daily_reconciliations_on_business_id"

    remove_foreign_key :daily_reconciliations, :branches
    remove_foreign_key :daily_reconciliations, :businesses

    remove_column :daily_reconciliations, :branch_id
    remove_column :daily_reconciliations, :business_id
    remove_column :daily_reconciliations, :business_date

    add_reference :daily_reconciliations, :till_session,
                  null: false,
                  foreign_key: true,
                  index: { unique: true, name: "idx_daily_reconciliations_unique_session" }
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
