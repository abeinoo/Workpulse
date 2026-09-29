# Inventory Overview — the daily operations dashboard. Composes existing
# services only; no stock arithmetic lives here:
#   KPIs / stock value / out of stock  → Inventory::Reports::Overview (CurrentStock, LowStockQuery)
#   movement totals + trend             → Inventory::Reports::MovementSummary (grouped SQL over the ledger)
#   most active products                → Inventory::Reports::ActiveProducts (ConsumptionLedger)
#   warehouse snapshot                  → Inventory::Reports::WarehouseSummary
#   recent movements                    → Inventory::Reports::Movements (the Stock Movement report query)
#   purchase recommendations            → Inventory::Reports::LowStock (reorder settings)
# Every pending count uses the same policy scope + filter as the list page its
# card or action links to, so the number always matches what opens.
class Inventory::DashboardController < Inventory::BaseController
  ActionItem = Struct.new(:key, :level, :count, :path, keyword_init: true)
  PURCHASE_ROWS      = 10
  PERIOD_KEYS        = %w[today 7d 30d month].freeze
  ACTIVE_PERIOD_KEYS = %w[7d 30d month].freeze

  def index
    business = current_user.business
    wh_ids   = accessible_warehouse_ids # nil = all warehouses

    @overview   = Inventory::Reports::Overview.new(business, warehouse_ids: wh_ids)
    @period     = Inventory::Reports::Period.new(business, key: params[:period], from: params[:from], to: params[:to],
                                                           keys: PERIOD_KEYS + %w[custom])
    @movements  = Inventory::Reports::MovementSummary.new(business, period: @period, warehouse_ids: wh_ids)
    @active_period   = Inventory::Reports::Period.new(business, key: params[:active_period], keys: ACTIVE_PERIOD_KEYS)
    @active_products = Inventory::Reports::ActiveProducts.new(business, period: @active_period, warehouse_ids: wh_ids).rows

    @low_stock_alerts = @overview.low_stock_alerts
    # Most urgent first (out of stock, then lowest stock relative to its level);
    # the dashboard shows the top rows, the Low Stock report shows them all.
    @low_stock_rows   = Inventory::Reports::LowStock.rows_for(@low_stock_alerts)
                                                      .sort_by { |r| [ r.on_hand.positive? ? 1 : 0, r.on_hand / [ r.low_stock_level, 1 ].max, r.product.name ] }
    @suppliers        = business.suppliers.ordered
    @family_low_stock = @low_stock_alerts.select { |a| a.product.parent_product_id? }.group_by { |a| a.product.parent_product }

    @warehouses        = accessible_warehouses.to_a
    @warehouse_summary = Inventory::Reports::WarehouseSummary.new(business, warehouses: @warehouses, movement_summary: @movements,
                                                                            low_stock_alerts: @low_stock_alerts)

    load_pending_counts
    @action_items = build_action_items
    load_recent_movements(business, wh_ids)
    load_quick_product
  end

  private

  def load_pending_counts
    @open_purchase_requests = policy(PurchaseRequest).index? ? policy_scope(PurchaseRequest).needs_action.count : nil
    if policy(GoodsReceipt).index?
      receipts = policy_scope(GoodsReceipt)
      @receipts_pending_approval = receipts.for_approval_status("pending_approval").count
      @receipts_awaiting_receipt = receipts.for_approval_status("approved").for_receiving_status("not_received").count
    end
    if policy(StockIssue).index?
      issues = policy_scope(StockIssue).excluding_incomplete_imports
      @issues_pending_approval      = issues.for_status("pending_approval").count
      @issues_awaiting_confirmation = issues.for_status("approved").count
    end
    return unless policy(StockCount).index?

    # Stock adjustments post immediately; the adjustment workflow with a
    # pending state is the stock count (counted → awaiting approval).
    counts = policy_scope(StockCount)
    @counts_awaiting_approval = counts.where(status: "completed").count
    @counts_in_progress       = counts.where(status: "in_progress").count
  end

  # "يحتاج إلى إجراء" — only categories with something to do.
  def build_action_items
    items = [
      ActionItem.new(key: :out_of_stock, level: :critical, count: @overview.out_of_stock_count,
                     path: inventory_current_stock_report_path(stock_status: "out_of_stock")),
      ActionItem.new(key: :low_stock, level: :serious, count: @overview.low_stock_count,
                     path: inventory_low_stock_report_path),
      (ActionItem.new(key: :purchase_requests, level: :warning, count: @open_purchase_requests,
                      path: inventory_purchase_requests_path(needs_action: "1")) if @open_purchase_requests),
      (ActionItem.new(key: :receipts_pending_approval, level: :warning, count: @receipts_pending_approval,
                      path: inventory_goods_receipts_path(approval_status: "pending_approval")) if @receipts_pending_approval),
      (ActionItem.new(key: :receipts_awaiting_receipt, level: :warning, count: @receipts_awaiting_receipt,
                      path: inventory_goods_receipts_path(approval_status: "approved", receiving_status: "not_received")) if @receipts_awaiting_receipt),
      (ActionItem.new(key: :issues_pending_approval, level: :warning, count: @issues_pending_approval,
                      path: inventory_stock_issues_path(workflow_status: "pending_approval")) if @issues_pending_approval),
      (ActionItem.new(key: :issues_awaiting_confirmation, level: :warning, count: @issues_awaiting_confirmation,
                      path: inventory_stock_issues_path(workflow_status: "approved")) if @issues_awaiting_confirmation),
      (ActionItem.new(key: :counts_awaiting_approval, level: :warning, count: @counts_awaiting_approval,
                      path: inventory_stock_counts_path(status: "completed")) if @counts_awaiting_approval),
      (ActionItem.new(key: :counts_in_progress, level: :warning, count: @counts_in_progress,
                      path: inventory_stock_counts_path(status: "in_progress")) if @counts_in_progress)
    ]
    items.compact.select { |item| item.count.positive? }
  end

  # The Stock Movement report's own query (newest first, with source documents
  # and ledger balances) — one page, plus the consuming branches in one query.
  def load_recent_movements(business, wh_ids)
    @recent_movements = Inventory::Reports::Movements.new(business, warehouse_ids: wh_ids).page(1, 8)
    branch_ids = @recent_movements.map { |r| r.movement.branch_id || (r.source.branch_id if r.source.respond_to?(:branch_id)) }
    @recent_branches = business.branches.where(id: branch_ids.compact.uniq).index_by(&:id)
  end

  def load_quick_product
    @search_products = policy_scope(Product).transactable.ordered
    @quick_product   = @search_products.find_by(id: params[:product_id]) if params[:product_id].present?
  end
end
