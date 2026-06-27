class RestructureTillDeposits < ActiveRecord::Migration[8.1]
  def up
    add_reference :till_deposits, :till_session,
                  null: false,
                  foreign_key: true,
                  index: true

    add_index :till_deposits,
              [:till_session_id, :payment_method_id],
              name: "idx_till_deposits_session_method"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
