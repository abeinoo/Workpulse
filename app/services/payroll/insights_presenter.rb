class Payroll::InsightsPresenter
  def initialize(period:, entries:)
    @period  = period
    @entries = entries
  end

  # % change in net payroll vs previous month.
  # Returns { change_pct: Float, current: Float, previous: Float } or nil if no previous period.
  def payroll_change
    @payroll_change ||= compute_payroll_change
  end

  # Full metric comparison vs previous month.
  # Returns { prev_period_label:, employees:, net:, overtime:, deductions:, bonuses: } or nil.
  # Each metric: { current:, previous:, diff:, pct: Float|nil }
  def comparison
    @comparison ||= compute_comparison
  end

  def top_overtime(limit: 5)
    @top_overtime ||= @entries
                        .select { |e| e.total_overtime > 0 }
                        .sort_by { |e| -e.total_overtime }
                        .first(limit)
  end

  def top_deductions(limit: 5)
    @top_deductions ||= @entries
                          .select { |e| e.total_deductions > 0 }
                          .sort_by { |e| -e.total_deductions }
                          .first(limit)
  end

  # Entries where overtime exceeds threshold% of base salary (default 30%).
  def abnormal_overtime_entries(threshold: 0.30)
    @abnormal_overtime_entries ||= @entries.select { |e|
      e.base_salary > 0 && e.total_overtime > e.base_salary * threshold
    }
  end

  # Set of user_ids who have at least one incomplete checkout in this period.
  def incomplete_checkout_user_ids
    @incomplete_checkout_user_ids ||= AttendanceRecord
      .for_business(@period.business)
      .for_period(@period.period_start, @period.period_end)
      .incomplete
      .pluck(:user_id)
      .to_set
  end

  # Count derived from the already-memoized set (avoids a second DB query).
  def incomplete_checkouts_count
    incomplete_checkout_user_ids.size
  end

  # Per-branch average lateness minutes for this period's employees.
  def branch_lateness_ranking(limit: 5)
    @branch_lateness_ranking ||= compute_branch_lateness_ranking(limit: limit)
  end

  # Net payroll per month for the last N months including current.
  # Returns array of { label: String, net: Float|nil, is_current: Boolean }
  def net_payroll_trend(months: 6)
    @net_payroll_trend ||= compute_net_payroll_trend(months: months)
  end

  private

  def compute_payroll_change
    prev_m, prev_y = prev_month_and_year
    prev_period = PayrollPeriod.find_by(
      business_id:  @period.business_id,
      period_year:  prev_y,
      period_month: prev_m
    )
    return nil unless prev_period

    prev_net = prev_period.payroll_entries.sum(:net_salary).to_f
    curr_net = @entries.sum(&:net_salary).to_f
    return nil if prev_net.zero?

    change_pct = ((curr_net - prev_net) / prev_net * 100).round(1)
    { change_pct: change_pct, current: curr_net, previous: prev_net }
  end

  def compute_comparison
    prev_m, prev_y = prev_month_and_year
    prev_period = PayrollPeriod.find_by(
      business_id:  @period.business_id,
      period_year:  prev_y,
      period_month: prev_m
    )
    return nil unless prev_period

    prev_entries = prev_period.payroll_entries
    prev_count   = prev_entries.count
    prev_net     = prev_entries.sum(:net_salary).to_f
    prev_ot      = prev_entries.sum(:total_overtime).to_f
    prev_ded     = prev_entries.sum(:total_deductions).to_f
    prev_bon     = prev_entries.sum(:total_bonuses).to_f

    curr_count = @entries.size
    curr_net   = @entries.sum(&:net_salary).to_f
    curr_ot    = @entries.sum(&:total_overtime).to_f
    curr_ded   = @entries.sum(&:total_deductions).to_f
    curr_bon   = @entries.sum(&:total_bonuses).to_f

    {
      prev_period_label: prev_period.period_label,
      employees:  build_delta(curr_count, prev_count, currency: false),
      net:        build_delta(curr_net,   prev_net),
      overtime:   build_delta(curr_ot,    prev_ot),
      deductions: build_delta(curr_ded,   prev_ded),
      bonuses:    build_delta(curr_bon,   prev_bon),
    }
  end

  def build_delta(current, previous, currency: true)
    diff = current.to_f - previous.to_f
    pct  = previous.to_f.nonzero? ? (diff / previous.to_f * 100).round(1) : nil
    { current: current, previous: previous, diff: diff, pct: pct, currency: currency }
  end

  def prev_month_and_year
    m = @period.period_month - 1
    y = @period.period_year
    if m.zero?
      m = 12
      y -= 1
    end
    [m, y]
  end

  def compute_branch_lateness_ranking(limit:)
    user_ids = @entries.map(&:user_id)
    return [] if user_ids.empty?

    records = AttendanceRecord
      .for_business(@period.business)
      .for_period(@period.period_start, @period.period_end)
      .where(user_id: user_ids)
      .pluck(:user_id, :late_minutes, :early_leave_minutes)

    user_totals = records.each_with_object(Hash.new(0)) do |(uid, late, early), h|
      h[uid] += late.to_i + early.to_i
    end

    branch_lookup = ShiftAssignment.branch_names_by_user(
      user_ids, from: @period.period_start, to: @period.period_end
    )

    branch_data = Hash.new { |h, k| h[k] = { total: 0, count: 0 } }
    user_totals.each do |uid, mins|
      bname = branch_lookup[uid] || "—"
      branch_data[bname][:total] += mins
      branch_data[bname][:count] += 1
    end

    branch_data.map do |name, d|
      avg = d[:count] > 0 ? (d[:total].to_f / d[:count]).round : 0
      { branch: name, avg_late_minutes: avg, employee_count: d[:count] }
    end.sort_by { |b| -b[:avg_late_minutes] }.first(limit)
  end

  def compute_net_payroll_trend(months:)
    months_list = (0...months).map do |offset|
      m = @period.period_month - (months - 1 - offset)
      y = @period.period_year
      while m <= 0
        m += 12
        y -= 1
      end
      [y, m]
    end

    conditions = months_list.map { |y, m|
      "(period_year = #{y.to_i} AND period_month = #{m.to_i})"
    }.join(" OR ")

    period_ids_by_ym = PayrollPeriod
      .where(business_id: @period.business_id)
      .where(conditions)
      .pluck(:period_year, :period_month, :id)
      .each_with_object({}) { |(y, m, id), h| h[[y, m]] = id }

    all_ids = period_ids_by_ym.values
    net_by_period = all_ids.any? ?
      PayrollEntry.where(payroll_period_id: all_ids).group(:payroll_period_id).sum(:net_salary) : {}

    months_list.map do |y, m|
      pid = period_ids_by_ym[[y, m]]
      {
        label:      I18n.t("date.abbr_month_names")[m],
        net:        pid ? net_by_period[pid].to_f : nil,
        is_current: y == @period.period_year && m == @period.period_month
      }
    end
  end
end
