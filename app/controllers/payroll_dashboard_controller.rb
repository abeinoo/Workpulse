class PayrollDashboardController < ApplicationController
  before_action :authenticate_user!

  def index
    authorize :payroll_dashboard, :index?

    business = current_user.business

    # ── 6-month trend ────────────────────────────────────────────────────────
    @trend = build_trend(business, months: 6)

    # ── Most-recent finalized/paid period aggregates ─────────────────────────
    recent = PayrollPeriod
      .where(business: business, status: %w[finalized paid])
      .order(period_year: :desc, period_month: :desc)
      .first

    if recent
      @recent_label     = recent.period_label
      @recent_net       = recent.payroll_entries.sum(:net_salary)
      @recent_base      = recent.payroll_entries.sum(:base_salary)
      @recent_overtime  = recent.payroll_entries.sum(:total_overtime)
      @recent_deductions = recent.payroll_entries.sum(:total_deductions)
      @recent_employees = recent.payroll_entries.count

      # Branch cost breakdown for the most recent period
      @branch_costs = build_branch_costs(recent)

      # Top 5 employees by net salary
      @top_employees = recent.payroll_entries
                             .includes(:user)
                             .order(net_salary: :desc)
                             .limit(5)
    end

    # ── Pending / in-progress periods ────────────────────────────────────────
    @pending_periods = PayrollPeriod
      .where(business: business)
      .where.not(status: %w[paid])
      .order(period_year: :desc, period_month: :desc)
      .limit(5)

    # ── Health score ─────────────────────────────────────────────────────────
    @health = build_health_score(business)

    # ── Smart recommendations ────────────────────────────────────────────────
    @recommendations = Payroll::RecommendationEngine.new(business: business).recommendations
  end

  private

  def build_trend(business, months:)
    now_m = Date.today.month
    now_y = Date.today.year

    month_list = (0...months).map do |offset|
      m = now_m - (months - 1 - offset)
      y = now_y
      while m <= 0; m += 12; y -= 1; end
      [y, m]
    end

    conditions = month_list.map { |y, m|
      "(period_year = #{y.to_i} AND period_month = #{m.to_i})"
    }.join(" OR ")

    periods_by_ym = PayrollPeriod
      .where(business: business)
      .where(conditions)
      .pluck(:period_year, :period_month, :id)
      .each_with_object({}) { |(y, m, id), h| h[[y, m]] = id }

    all_ids = periods_by_ym.values
    net_by_pid = all_ids.any? ?
      PayrollEntry.where(payroll_period_id: all_ids).group(:payroll_period_id).sum(:net_salary) :
      {}
    ot_by_pid = all_ids.any? ?
      PayrollEntry.where(payroll_period_id: all_ids).group(:payroll_period_id).sum(:total_overtime) :
      {}

    month_list.map do |y, m|
      pid = periods_by_ym[[y, m]]
      {
        label:   Date::MONTHNAMES[m].first(3),
        net:     pid ? net_by_pid[pid].to_f : nil,
        overtime: pid ? ot_by_pid[pid].to_f : nil,
      }
    end
  end

  def build_branch_costs(period)
    entry_ids = period.payroll_entries.pluck(:id, :user_id)
    return [] if entry_ids.empty?

    user_ids   = entry_ids.map(&:last)
    net_by_entry = period.payroll_entries.pluck(:id, :net_salary).to_h

    branch_lookup = ShiftAssignment.branch_names_by_user(
      user_ids, from: period.period_start, to: period.period_end
    )

    period.payroll_entries
          .pluck(:id, :user_id, :net_salary)
          .each_with_object(Hash.new(0.0)) do |(eid, uid, net), h|
            branch = branch_lookup[uid] || t("payroll_dashboard.no_branch")
            h[branch] += net.to_f
          end
          .sort_by { |_, v| -v }
          .first(6)
          .map { |name, total| { name: name, total: total } }
  end

  def build_health_score(business)
    all = PayrollPeriod.where(business: business)
    return { score: 100, label: :excellent } if all.none?

    paid_finalized = all.where(status: %w[paid finalized]).count
    total          = all.count
    base           = total > 0 ? ((paid_finalized.to_f / total) * 60).round : 0

    draft_count   = all.where(status: "draft").count
    review_count  = all.where(status: %w[under_review branch_review_completed]).count
    draft_penalty = [ draft_count * 5, 20 ].min
    review_bonus  = [ review_count * 5, 20 ].min

    score = [ [ base - draft_penalty + review_bonus + 20, 100 ].min, 0 ].max

    label = case score
            when 85..100 then :excellent
            when 65..84  then :good
            when 45..64  then :fair
            else              :poor
            end

    { score: score, label: label }
  end
end
