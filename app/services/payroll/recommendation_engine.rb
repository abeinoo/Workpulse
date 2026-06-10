module Payroll
  # Generates human-readable operational recommendations for a business.
  # Combines payroll data and attendance patterns to surface actionable insights.
  #
  # Usage:
  #   Payroll::RecommendationEngine.new(business: business).recommendations
  class RecommendationEngine
    OVERTIME_BRANCH_THRESHOLD = 0.20   # branch OT / branch net > 20%
    PAYROLL_SPIKE_THRESHOLD   = 0.15   # 15% increase vs rolling average
    LATE_RATE_THRESHOLD       = 0.25   # 25% of employees in branch are late repeatedly

    Recommendation = Struct.new(
      :code, :severity, :title, :body, :context,
      keyword_init: true
    )

    def initialize(business:, lookback_months: 3)
      @business        = business
      @lookback_months = lookback_months
    end

    def recommendations
      recs = [
        *branch_overtime_alerts,
        *payroll_cost_spike,
        *high_branch_lateness,
        *employees_needing_schedule_adjustment,
        *pending_payroll_review_warning,
        *missing_checkout_pattern
      ]
      recs.sort_by { |r| severity_rank(r.severity) }
    end

    private

    # ── Branch overtime ───────────────────────────────────────────────────────

    def branch_overtime_alerts
      period = latest_period
      return [] unless period

      branch_data(period).filter_map do |branch_name, data|
        next if data[:net].zero?
        ot_ratio = data[:overtime] / data[:net]
        next if ot_ratio < OVERTIME_BRANCH_THRESHOLD

        Recommendation.new(
          code:     :high_branch_overtime,
          severity: :warning,
          title:    I18n.t("recommendations.high_branch_overtime.title", branch: branch_name),
          body:     I18n.t("recommendations.high_branch_overtime.body",
                           branch: branch_name, pct: (ot_ratio * 100).round),
          context:  { branch: branch_name, ot_ratio: ot_ratio.round(3) }
        )
      end
    end

    # ── Payroll cost spike ────────────────────────────────────────────────────

    def payroll_cost_spike
      periods = recent_periods(@lookback_months + 1)
      return [] if periods.size < 2

      net_totals = periods.map { |p|
        p.payroll_entries.sum(:net_salary).to_f
      }

      current = net_totals.first
      average = net_totals.drop(1).sum / net_totals.drop(1).size.to_f
      return [] if average.zero?

      change = (current - average) / average

      return [] if change.abs < PAYROLL_SPIKE_THRESHOLD

      direction = change > 0 ? :increased : :decreased
      Recommendation.new(
        code:     :payroll_cost_spike,
        severity: change > 0 ? :warning : :info,
        title:    I18n.t("recommendations.payroll_cost_spike.title_#{direction}"),
        body:     I18n.t("recommendations.payroll_cost_spike.body_#{direction}",
                         pct: (change.abs * 100).round),
        context:  { change_pct: (change * 100).round(1) }
      ).then { |r| [r] }
    rescue
      []
    end

    # ── Branch lateness ───────────────────────────────────────────────────────

    def high_branch_lateness
      today = BusinessDay.current(context: @business)
      from  = today.beginning_of_month
      branches = @business.branches.active

      branches.filter_map do |branch|
        emp_ids = User.active
                      .where(id: ShiftAssignment.user_ids_for_branches([ branch.id ], on: today))
                      .pluck(:id)
        next if emp_ids.empty?

        late_count = AttendanceRecord
          .where(user_id: emp_ids, work_date: from..today)
          .where(status: "late")
          .select(:user_id).distinct.count

        late_rate = late_count.to_f / emp_ids.size
        next if late_rate < LATE_RATE_THRESHOLD

        Recommendation.new(
          code:     :high_branch_lateness,
          severity: :warning,
          title:    I18n.t("recommendations.high_branch_lateness.title",
                           branch: branch.name),
          body:     I18n.t("recommendations.high_branch_lateness.body",
                           branch: branch.name,
                           count: late_count,
                           pct:   (late_rate * 100).round),
          context:  { branch_id: branch.id, late_rate: late_rate.round(3) }
        )
      end
    end

    # ── Schedule adjustment candidates ───────────────────────────────────────

    def employees_needing_schedule_adjustment
      to   = BusinessDay.current(context: @business)
      from = to.beginning_of_month

      @business.users.active.find_each.filter_map do |user|
        result = Employee::PerformanceScorer.call(user: user, from: from, to: to)
        next if result.score >= 55  # fair or better — no recommendation
        next if result.total_days < 5  # insufficient data

        Recommendation.new(
          code:     :schedule_adjustment_needed,
          severity: :info,
          title:    I18n.t("recommendations.schedule_adjustment.title",
                           name: "#{user.first_name} #{user.last_name}"),
          body:     I18n.t("recommendations.schedule_adjustment.body",
                           name: user.first_name, score: result.score),
          context:  { user_id: user.id, score: result.score }
        )
      end.first(3)  # cap at 3 to avoid overwhelming the dashboard
    end

    # ── Pending payroll ───────────────────────────────────────────────────────

    def pending_payroll_review_warning
      draft_count = PayrollPeriod
        .where(business: @business, status: %w[draft under_review])
        .count
      return [] if draft_count.zero?

      oldest = PayrollPeriod
        .where(business: @business, status: %w[draft under_review])
        .order(period_year: :asc, period_month: :asc)
        .first

      [ Recommendation.new(
          code:     :pending_payroll_review,
          severity: draft_count > 1 ? :warning : :info,
          title:    I18n.t("recommendations.pending_payroll_review.title", count: draft_count),
          body:     I18n.t("recommendations.pending_payroll_review.body",
                           label: oldest.period_label),
          context:  { count: draft_count, oldest_period_id: oldest.id }
        ) ]
    end

    # ── Missing checkout pattern ──────────────────────────────────────────────

    def missing_checkout_pattern
      yesterday = BusinessDay.current(context: @business) - 1
      missing = AttendanceRecord
        .joins(:user)
        .where(users: { business_id: @business.id, active: true })
        .where(date: yesterday, status: "incomplete")
        .count
      return [] if missing < 3

      [ Recommendation.new(
          code:     :missing_checkouts_pattern,
          severity: :info,
          title:    I18n.t("recommendations.missing_checkouts.title"),
          body:     I18n.t("recommendations.missing_checkouts.body", count: missing),
          context:  { count: missing, date: yesterday }
        ) ]
    end

    # ── Data helpers ──────────────────────────────────────────────────────────

    def latest_period
      @latest_period ||= PayrollPeriod
        .where(business: @business)
        .where(status: %w[finalized paid])
        .order(period_year: :desc, period_month: :desc)
        .first
    end

    def recent_periods(count)
      PayrollPeriod
        .where(business: @business)
        .order(period_year: :desc, period_month: :desc)
        .limit(count)
        .includes(:payroll_entries)
        .to_a
    end

    def branch_data(period)
      entries  = period.payroll_entries.pluck(:user_id, :net_salary, :total_overtime)
      user_ids = entries.map(&:first)

      branch_map = ShiftAssignment.branch_names_by_user(
        user_ids, from: period.period_start, to: period.period_end
      )

      entries.each_with_object(Hash.new { |h, k| h[k] = { net: 0.0, overtime: 0.0 } }) do |(uid, net, ot), h|
        name = branch_map[uid] || I18n.t("payroll_dashboard.no_branch")
        h[name][:net]      += net.to_f
        h[name][:overtime] += ot.to_f
      end
    end

    def severity_rank(sev)
      { danger: 0, warning: 1, info: 2 }.fetch(sev.to_sym, 3)
    end
  end
end
