class AddBranchToInventoryConsumption < ActiveRecord::Migration[8.1]
  # Branch attribution for inventory consumption, feeding branch profitability.
  #
  # Consumption is carried directly on the document/ledger row (a shared warehouse
  # can serve multiple branches). StockIssuePoster propagates a stock issue's
  # branch_id onto the OUT movements it writes; BranchProfitability sums
  # quantity × unit_cost of those movements per branch/period.
  #
  # The column is nullable at the DB level so existing rows stay valid and posted
  # documents remain voidable. New stock issues require a branch (validated in the
  # model, on :create); goods-receipt / adjustment / transfer movements keep
  # branch_id NULL and simply go unattributed in profitability — by design.
  def change
    add_reference :stock_issues,        :branch, foreign_key: true, index: true
    add_reference :inventory_movements, :branch, foreign_key: true, index: true
  end
end
