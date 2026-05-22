class NormalizeLegacyAdjustmentTypes < ActiveRecord::Migration[8.1]
  LEGACY_TYPES = %w[bonus reward eid_bonus].freeze

  def up
    # Normalize PayrollAdjustment records — legacy types map to cash_incentive.
    # These types were removed from the enum; existing DB rows would load with
    # adjustment_type: nil, causing payroll regeneration to fail.
    execute <<~SQL
      UPDATE payroll_adjustments
      SET adjustment_type = 'cash_incentive'
      WHERE adjustment_type IN ('bonus', 'reward', 'eid_bonus')
    SQL

    # Normalize corresponding PayrollLineItem records for the same reason.
    execute <<~SQL
      UPDATE payroll_line_items
      SET item_type = 'cash_incentive'
      WHERE item_type IN ('bonus', 'reward', 'eid_bonus')
    SQL

    say "Normalized #{affected_count} records total"
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Cannot restore original bonus/reward/eid_bonus distinction after normalization"
  end

  private

  def affected_count
    PayrollAdjustment.where(adjustment_type: "cash_incentive").count +
      PayrollLineItem.where(item_type: "cash_incentive").count
  end
end
