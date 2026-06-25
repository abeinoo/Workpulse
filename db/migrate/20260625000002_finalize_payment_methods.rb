class FinalizePaymentMethods < ActiveRecord::Migration[8.1]
  def change
    # Rename the vague 'payment_category' column to the domain-accurate
    # 'settlement_type' used throughout the approved architecture.
    rename_column :payment_methods, :payment_category, :settlement_type

    # Drop the old index referencing the old column name.
    remove_index :payment_methods,
                 name: "idx_payment_methods_on_business_and_category",
                 if_exists: true

    add_index :payment_methods, %i[business_id settlement_type],
              name: "index_payment_methods_on_business_id_and_settlement_type"

    # Whether this method can produce refund lines on a handover.
    add_column :payment_methods, :supports_refunds, :boolean, null: false, default: true

    # Back-fill Cash to settlement_type 'cash' so the till-deposit workflow
    # knows which methods reach the ATM. Everything else stays 'other' until
    # the business configures it.
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE payment_methods
          SET    settlement_type = 'cash'
          WHERE  lower(name) IN ('cash', 'نقداً', 'نقد')
        SQL
      end
    end
  end
end
