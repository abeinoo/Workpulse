class AddClosingFieldsToTillHandovers < ActiveRecord::Migration[8.1]
  def change
    add_column :till_handovers, :fresha_date,  :date
    add_column :till_handovers, :self_deposit, :boolean, null: false, default: false

    add_column :till_handover_amounts, :kind, :string, null: false, default: "operational"

    remove_index :till_handover_amounts, name: "idx_till_handover_amounts_unique_method"
    add_index :till_handover_amounts,
              %i[till_handover_id payment_method_id kind],
              unique: true,
              name: "idx_till_handover_amounts_unique_method_kind"
  end
end
