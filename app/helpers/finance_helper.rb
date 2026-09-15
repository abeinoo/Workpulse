module FinanceHelper
  SETTLEMENT_TYPE_BADGES = {
    "cash"    => "badge-info",
    "card"    => "badge-primary",
    "ewallet" => "badge-warning",
    "voucher" => "badge-secondary",
    "other"   => ""
  }.freeze

  def settlement_type_badge_class(type)
    SETTLEMENT_TYPE_BADGES.fetch(type.to_s, "")
  end

  # Shared by the Expense show page's Financial Information card and the
  # Expenses Index payment-status column, so both read the exact same
  # pending_settlement/partially_settled/settled classification (Settleable's
  # #financial_status) with one badge/label mapping.
  EXPENSE_FINANCIAL_STATUS_BADGES = {
    "pending_settlement" => "badge-warning",
    "partially_settled"  => "badge-accent",
    "settled"            => "badge-success"
  }.freeze

  def expense_financial_status_badge_class(financial_status)
    EXPENSE_FINANCIAL_STATUS_BADGES.fetch(financial_status.to_s, "badge-neutral")
  end

  # Classifies a (paid, total) pair using the same three states as
  # Settleable#financial_status, for callers (the Expenses Index) that
  # preload paid sums in bulk instead of calling the per-record association
  # method — avoids an N+1 SUM query per row while staying data-shape-derived,
  # never a stored flag.
  def expense_payment_status(paid, total)
    return "settled" if paid >= total
    return "pending_settlement" if paid <= 0

    "partially_settled"
  end

  # A qualitative status badge derived from numbers the dashboard controller
  # already computed (net profit sign, pending approvals, overdue deposits,
  # negative custody) — the same kind of view-level categorization
  # _kpi_cards.html.erb already does (e.g. `net.negative? ? 'kpi-card--danger'
  # : ...`). No new money is calculated here, only a label describing
  # existing figures. Shared by the header badge and the full Financial
  # Health card so both read the exact same status from one place.
  #
  # Returns [status_symbol, factors_array_of_strings].
  def finance_dashboard_health(show_profitability:, net_profit:, pending_count:, overdue_count:, negative_custody_count:)
    factors = []
    factors << t("finance.dashboard.financial_health.factor_net_negative") if show_profitability && net_profit&.negative?
    factors << t("finance.dashboard.financial_health.factor_pending", count: pending_count) if pending_count.to_i > 5
    factors << t("finance.dashboard.financial_health.factor_overdue", count: overdue_count) if overdue_count.to_i > 0
    factors << t("finance.dashboard.financial_health.factor_negative_custody", count: negative_custody_count) if negative_custody_count.to_i > 0

    status = factors.empty? ? :healthy : (factors.size == 1 ? :attention : :at_risk)
    [ status, factors ]
  end

  # Single source of truth for building a link back to the Finance Dashboard
  # that preserves every currently-active filter (branch/date/cashier/payment)
  # except whatever `overrides` explicitly changes — used by cross-filter
  # chart clicks (e.g. a branch slice narrowing the dashboard's own branch
  # filter) and the active-filter chips' "×" links (pass the one key to drop
  # as `nil`). Every caller reads the exact same params, so there is only one
  # place that knows the dashboard's filter param shape.
  def finance_dashboard_url(overrides = {})
    finance_root_path({
      from: params[:from], to: params[:to], branch_id: params[:branch_id],
      cashier_id: params[:cashier_id], payment_source: params[:payment_source],
      payment_method_id: params[:payment_method_id]
    }.merge(overrides).compact_blank)
  end
end
