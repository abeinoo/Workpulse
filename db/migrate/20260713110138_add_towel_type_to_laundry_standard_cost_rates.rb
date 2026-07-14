class AddTowelTypeToLaundryStandardCostRates < ActiveRecord::Migration[8.1]
  def change
    # Nullable: the rate model was previously one global cost per business,
    # with no towel-type concept. Any pre-existing row therefore cannot be
    # safely (or honestly) attributed to a specific towel type — reassigning
    # it to one arbitrarily would fabricate history that never existed. Such
    # rows are left with towel_type_id: nil and are permanently excluded from
    # per-towel-type rate resolution (LaundryStandardCostRate.effective_for
    # now always scopes by towel_type) — they remain in the table only as
    # inert historical data, never edited/deleted per the append-only design.
    # All new rows require a towel_type_id via the model-level validation.
    add_reference :laundry_standard_cost_rates, :towel_type, null: true, foreign_key: true
    add_index :laundry_standard_cost_rates, [ :towel_type_id, :effective_from ],
              name: "idx_on_towel_type_id_effective_from"
  end
end
