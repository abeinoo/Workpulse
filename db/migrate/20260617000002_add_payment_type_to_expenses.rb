class AddPaymentTypeToExpenses < ActiveRecord::Migration[8.1]
  def change
    add_column :expenses, :payment_type, :string, null: false, default: "pending_payment"
    add_index  :expenses, [ :business_id, :payment_type ]
  end
end
