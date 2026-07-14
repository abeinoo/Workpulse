class CreateLaundryStandardCostRates < ActiveRecord::Migration[8.1]
  def change
    # Effective-dated rate history — rows are never edited or deleted; changing
    # the rate inserts a new row. "Rate effective at time T" = the row with the
    # latest effective_from <= T. Deliberately not the flat settings JSON
    # pattern (Business#settings) because this value needs history, and not a
    # column on towel_transfers/towel_ledger_entries because those must never
    # be mutated.
    create_table :laundry_standard_cost_rates do |t|
      t.references :business, null: false, foreign_key: true
      t.decimal :cost_per_towel, precision: 12, scale: 4, null: false
      t.datetime :effective_from, null: false
      t.references :created_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :laundry_standard_cost_rates, [ :business_id, :effective_from ]
  end
end
