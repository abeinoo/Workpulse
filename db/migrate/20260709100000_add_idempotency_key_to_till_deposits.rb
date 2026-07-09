class AddIdempotencyKeyToTillDeposits < ActiveRecord::Migration[8.1]
  def change
    add_column :till_deposits, :idempotency_key, :string

    add_index :till_deposits, :idempotency_key,
              unique: true,
              where:  "idempotency_key IS NOT NULL",
              name:   "index_till_deposits_on_idempotency_key"
  end
end
