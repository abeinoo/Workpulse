module Finance
  module Dashboard
    # Turns numbers the dashboard has already computed (current vs. previous
    # period category/branch/payroll totals) into a short list of plain-language
    # insights, following the same Struct + severity + per-rule-method shape as
    # Payroll::RecommendationEngine. No new financial calculation happens here —
    # every rule only compares figures the controller already computed.
    #
    # Only emits an insight when a rule crosses its threshold, so the panel
    # never fills up with noise ("only show meaningful insights").
    class InsightsGenerator
      CATEGORY_CHANGE_THRESHOLD = 0.15   # ±15% vs previous period
      BRANCH_SHARE_THRESHOLD    = 0.25   # branch is ≥25% of total expenses
      PAYROLL_SHARE_THRESHOLD   = 0.35   # payroll is ≥35% of operating cost
      MAX_INSIGHTS = 5

      Insight = Struct.new(:severity, :title, :body, keyword_init: true)

      def initialize(by_category:, by_category_previous:, by_branch:, total_expenses:,
                      payroll_cost: nil, operating_cost: nil, profitability_rows: nil)
        @by_category          = by_category
        @by_category_previous = by_category_previous
        @by_branch            = by_branch
        @total_expenses       = total_expenses.to_f
        @payroll_cost         = payroll_cost
        @operating_cost       = operating_cost
        @profitability_rows   = profitability_rows
      end

      def insights
        [ *branch_performance_insights, *top_category_insight,
          *category_change_insights, *branch_share_insights, *payroll_share_insight ]
          .first(MAX_INSIGHTS)
      end

      private

      # Best/worst branch by net profit for the month — picked from the same
      # Finance::Reports::BranchProfitability rows the KPI cards and the
      # profitability chart already render (@profitability), not a new query
      # or calculation. Always shown when there's more than one branch to
      # compare; a single branch has nothing to rank against.
      def branch_performance_insights
        return [] if @profitability_rows.blank? || @profitability_rows.size < 2

        best  = @profitability_rows.max_by { |r| r[:net] }
        worst = @profitability_rows.min_by { |r| r[:net] }
        return [] if best[:branch] == worst[:branch]

        [
          Insight.new(severity: :info,
            title: I18n.t("finance.dashboard.insights.best_branch.title", branch: best[:branch]),
            body: I18n.t("finance.dashboard.insights.best_branch.body", branch: best[:branch])),
          Insight.new(severity: worst[:net].negative? ? :warning : :info,
            title: I18n.t("finance.dashboard.insights.worst_branch.title", branch: worst[:branch]),
            body: I18n.t("finance.dashboard.insights.worst_branch.body", branch: worst[:branch]))
        ]
      end

      # The single highest expense category and its share of total expenses —
      # an always-on fact (unlike category_change_insights below, which only
      # fires on a ±15% swing vs the previous period), picked from @by_category
      # which is already sorted descending by amount.
      def top_category_insight
        return [] if @by_category.blank? || @total_expenses.zero?

        name, amount = @by_category.first
        share = (amount.to_f / @total_expenses * 100).round

        [ Insight.new(
            severity: :info,
            title: I18n.t("finance.dashboard.insights.top_category.title", category: name),
            body: I18n.t("finance.dashboard.insights.top_category.body", category: name, pct: share)
          ) ]
      end

      def category_change_insights
        @by_category.filter_map do |name, current|
          previous = @by_category_previous[name].to_f
          next if previous.zero?

          change = (current.to_f - previous) / previous
          next if change.abs < CATEGORY_CHANGE_THRESHOLD

          direction = change.positive? ? :increased : :decreased
          Insight.new(
            severity: change.positive? ? :warning : :info,
            title: I18n.t("finance.dashboard.insights.category_change.title_#{direction}",
                          category: name, pct: (change.abs * 100).round),
            body: I18n.t("finance.dashboard.insights.category_change.body_#{direction}",
                         category: name, pct: (change.abs * 100).round)
          )
        end
      end

      def branch_share_insights
        return [] if @total_expenses.zero?

        @by_branch.filter_map do |name, amount|
          share = amount.to_f / @total_expenses
          next if share < BRANCH_SHARE_THRESHOLD

          Insight.new(
            severity: :info,
            title: I18n.t("finance.dashboard.insights.branch_share.title",
                          branch: name, pct: (share * 100).round),
            body: I18n.t("finance.dashboard.insights.branch_share.body",
                         branch: name, pct: (share * 100).round)
          )
        end
      end

      def payroll_share_insight
        return [] if @payroll_cost.blank? || @operating_cost.blank? || @operating_cost.to_f.zero?

        share = @payroll_cost.to_f / @operating_cost.to_f
        return [] if share < PAYROLL_SHARE_THRESHOLD

        [ Insight.new(
            severity: :info,
            title: I18n.t("finance.dashboard.insights.payroll_share.title", pct: (share * 100).round),
            body: I18n.t("finance.dashboard.insights.payroll_share.body", pct: (share * 100).round)
          ) ]
      end
    end
  end
end
