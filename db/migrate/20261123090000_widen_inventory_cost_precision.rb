# Earlier decision 8 (docs/inventory/multi_unit_nested_packaging_design.md
# §11, §18 P1.A): stored unit costs and averages keep 8 decimal places, so a
# base-unit cost such as 25.00 / 355 ml = 0.07042254 is not rounded to 0.0704.
# Widening numeric(12,4) to numeric(16,8) keeps every existing value exactly
# (the integer part keeps 8 digits). Money totals (numeric(14,4)) are unchanged.
#
# down refuses once any value needs more than 4 decimal places: narrowing would
# silently round historical costs.
class WidenInventoryCostPrecision < ActiveRecord::Migration[8.1]
  COLUMNS = {
    inventory_movements:        %i[unit_cost],
    products:                   %i[average_cost_price initial_cost_price last_purchase_price],
    goods_receipt_items:        %i[unit_cost],
    stock_issue_items:          %i[unit_cost],
    stock_transfer_items:       %i[unit_cost],
    stock_adjustment_items:     %i[unit_cost],
    laundry_batch_consumptions: %i[unit_cost_snapshot],
    purchase_request_items:     %i[unit_price]
  }.freeze

  def up
    each_column { |table, column| change_column table, column, :decimal, precision: 16, scale: 8 }
  end

  def down
    each_column do |table, column|
      fine = select_value("SELECT count(*) FROM #{table} WHERE #{column} <> round(#{column}, 4)").to_i
      raise ActiveRecord::IrreversibleMigration, "#{table}.#{column} has #{fine} value(s) with more than 4 dp" if fine.positive?
    end
    each_column { |table, column| change_column table, column, :decimal, precision: 12, scale: 4 }
  end

  private

  def each_column
    COLUMNS.each { |table, columns| columns.each { |column| yield table, column } }
  end
end
