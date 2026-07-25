class AddAtmDepositFailureSupportToBankDisputes < ActiveRecord::Migration[8.1]
  def change
    change_column_null :bank_disputes, :till_deposit_id, true

    add_reference :bank_disputes, :daily_reconciliation, foreign_key: true

    add_column :bank_disputes, :kind, :string, null: false, default: "missing_from_bank"
    add_column :bank_disputes, :atm_location, :string

    add_index :bank_disputes, :kind
  end
end
