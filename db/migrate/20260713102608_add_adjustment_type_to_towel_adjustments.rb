class AddAdjustmentTypeToTowelAdjustments < ActiveRecord::Migration[8.1]
  def change
    add_column :towel_adjustments, :adjustment_type, :string, default: "correction", null: false
  end
end
