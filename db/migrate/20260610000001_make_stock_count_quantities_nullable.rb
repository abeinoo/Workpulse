class MakeStockCountQuantitiesNullable < ActiveRecord::Migration[8.1]
  # A preloaded count row starts UNCOUNTED: counted_quantity (and therefore the
  # derived difference) is NULL until someone enters a number — so "counted as 0"
  # is distinguishable from "not counted yet", which the counting UX, progress,
  # filters and the approval guard all depend on.
  def up
    change_column_null    :stock_count_items, :counted_quantity, true
    change_column_default :stock_count_items, :counted_quantity, from: 0.0, to: nil
    change_column_null    :stock_count_items, :difference, true
    change_column_default :stock_count_items, :difference, from: 0.0, to: nil
  end

  def down
    execute "UPDATE stock_count_items SET counted_quantity = 0 WHERE counted_quantity IS NULL"
    execute "UPDATE stock_count_items SET difference = 0 WHERE difference IS NULL"
    change_column_default :stock_count_items, :counted_quantity, from: nil, to: 0.0
    change_column_null    :stock_count_items, :counted_quantity, false
    change_column_default :stock_count_items, :difference, from: nil, to: 0.0
    change_column_null    :stock_count_items, :difference, false
  end
end
