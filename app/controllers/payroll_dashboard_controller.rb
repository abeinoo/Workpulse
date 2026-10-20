class PayrollDashboardController < ApplicationController
  before_action :authenticate_user!

  # Every payroll figure here is computed from the entries the viewer may see —
  # policy_scope(PayrollEntry), the view_payroll scope (configured, else the
  # hierarchy default; the whole business for the owner), as the API payroll
  # report — never from the whole business (decision of 2026-10-19). The branch
  # breakdown also lists only the branches of that scope
  # (PayrollEntryPolicy.visible_branch_ids). No request parameter affects either.
  def index
    authorize :payroll_dashboard, :index?

    business = current_user.business
    @scope_limited = !(current_user.owner? || current_user.scope_for(:view_payroll) == "business")

    # ── 6-month trend ────────────────────────────────────────────────────────
    @trend = build_trend(business, months: 6)

    # ── Most-recent finalized/paid period aggregates ─────────────────────────
    recent = PayrollPeriod
      .where(business: business, status: %w[finalized paid])
      .order(period_year: :desc, period_month: :desc)
      .first

    if recent
      recent_entries     = visible_entries.where(payroll_period: recent)
      @recent_label      = recent.period_label
      @recent_net        = recent_entries.sum(:net_salary)
      @recent_base       = recent_entries.sum(:base_salary)
      @recent_overtime   = recent_entries.sum(:total_overtime)
      @recent_deductions = recent_entries.sum(:total_deductions)
      @recent_employees  = recent_entries.count

      # Branch cost breakdown for the most recent period
      @branch_costs = build_branch_costs(recent)

      # Top 5 employees by net salary — named, per-employee pay — among the
      # same visible entries.
      @top_employees = recent_entries
                             .includes(:user)
                             .order(net_salary: :desc)
                             .limit(5)
                             .to_a
      Payroll::EntryViewAudit.record(actor: current_user, entries: @top_employees,
                                     source: "payroll_dashboard_top_employees")
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
    @recommendations = Payroll::RecommendationEngine.new(business: business, payroll_entries: visible_entries,
                                                         payroll_branch_ids: payroll_branch_ids).recommendations
  end

  private

  # The payroll entries the viewer may see (PayrollEntryPolicy::Scope).
  def visible_entries = policy_scope(PayrollEntry)

  # Branches whose payroll the viewer may see, by branch (view_payroll scope).
  def payroll_branch_ids
    @payroll_branch_ids ||= PayrollEntryPolicy.visible_branch_ids(current_user)
  end

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
      visible_entries.where(payroll_period_id: all_ids).group(:payroll_period_id).sum(:net_salary) :
      {}
    ot_by_pid = all_ids.any? ?
      visible_entries.where(payroll_period_id: all_ids).group(:payroll_period_id).sum(:total_overtime) :
      {}

    month_list.map do |y, m|
      pid = periods_by_ym[[y, m]]
      {
        label:   I18n.t("date.abbr_month_names")[m],
        net:     pid ? net_by_pid[pid].to_f : nil,
        overtime: pid ? ot_by_pid[pid].to_f : nil,
      }
    end
  end

  # Net pay per branch (the branch the employee worked at during the period,
  # as before) from the visible entries only, and only for branches of the
  # viewer's view_payroll scope — a branch outside it is not listed at all.
  # Visible entries with no branch in the period stay under "no branch".
  def build_branch_costs(period)
    entries = visible_entries.where(payroll_period: period).pluck(:user_id, :net_salary)
    return [] if entries.empty?

    branch_by_user = ShiftAssignment.branch_ids_by_user(entries.map(&:first), from: period.period_start, to: period.period_end)
    names          = current_user.business.branches.where(id: branch_by_user.values.uniq).pluck(:id, :name).to_h

    entries.each_with_object(Hash.new(0.0)) do |(uid, net), totals|
      branch_id = branch_by_user[uid]
      next if branch_id && !payroll_branch_ids.include?(branch_id)

      totals[branch_id ? names[branch_id] : t("payroll_dashboard.no_branch")] += net.to_f
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
