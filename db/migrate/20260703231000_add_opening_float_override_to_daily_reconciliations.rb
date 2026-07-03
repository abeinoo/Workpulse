class AddOpeningFloatOverrideToDailyReconciliations < ActiveRecord::Migration[8.1]
  def change
    add_column :daily_reconciliations, :opening_float_override_amounts, :jsonb, default: nil
  end
end
