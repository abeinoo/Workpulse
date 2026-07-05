module Dashboard
  # Collects all data needed by the Area Manager operational dashboard.
  # All data is derived from a minimal set of base queries so the dashboard
  # never generates N+1 queries regardless of how many branches or employees
  # are managed.
  #
  # "Absent" means: employee had an active ShiftAssignment today for the branch
  # but has no AttendanceRecord for today. It is not the AR status "absent" —
  # that status is rarely written by the system. Assignment-based absence is
  # the operationally meaningful definition.
  class AreaManagerData
    Result = Struct.new(
      :managed_branches,
      :branch_health,
      :critical_alerts,
      :branch_ranking,
      :pending_approvals,
      :workforce_coverage,
      :attendance_trend,
      :stats,
      keyword_init: true
    )

    def self.call(manager, branch_scope: nil)
      new(manager, branch_scope: branch_scope).call
    end

    # branch_scope: optional array of branch ids to analyse. When omitted, falls
    # back to the branches this user is the area manager of (legacy behaviour).
    # The dashboard passes the user's full accessible-branch scope so that
    # business-wide permission holders see every branch.
    def initialize(manager, branch_scope: nil)
      @manager      = manager
      @branch_scope = branch_scope
      @today        = BusinessDay.current(context: manager.business)
      @yesterday    = @today - 1
    end

    def call
      Result.new(
        managed_branches:   managed_branches,
        branch_health:      branch_health,
        critical_alerts:    critical_alerts,
        branch_ranking:     branch_ranking,
        pending_approvals:  pending_approvals,
        workforce_coverage: workforce_coverage,
        attendance_trend:   attendance_trend,
        stats:              stats
      )
    end

    private

    attr_reader :manager, :today, :yesterday

    # ── Base relations — each executes exactly once ────────────────────────────

    def managed_branches
      @managed_branches ||= begin
        relation = @branch_scope ? Branch.where(id: @branch_scope) : Branch.where(area_manager: manager)
        relation.includes(:branch_manager).active.order(:name)
      end
    end

    def branch_ids
      @branch_ids ||= managed_branches.pluck(:id)
    end

    # Hash: branch_id → [user_ids] for branch members. Membership is shift-driven:
    # an employee belongs to a branch while they hold an active ShiftAssignment to
    # it (active today for this current-day dashboard).
    def employees_by_branch
      @employees_by_branch ||= begin
        mapping = Hash.new { |h, k| h[k] = [] }
        ShiftAssignment
          .active_on(today)
          .where(branch_id: branch_ids)
          .joins(:user)
          .where(users: { active: true })
          .distinct
          .pluck(:branch_id, :user_id)
          .each { |bid, uid| mapping[bid] << uid }
        mapping
      end
    end

    def all_employee_ids
      @all_employee_ids ||= employees_by_branch.values.flatten.uniq
    end

    # Array of [user_id, branch_id] for today's shift assignments.
    def today_assignments
      @today_assignments ||= ShiftAssignment
        .active_on(today)
        .where(branch_id: branch_ids)
        .pluck(:user_id, :branch_id)
    end

    def today_records
      @today_records ||= AttendanceRecord
        .active
        .where(user_id: all_employee_ids, date: today)
        .includes(:user)
        .to_a
    end

    # Only incomplete records from yesterday (for missing-checkout alerts).
    def missing_checkouts_yesterday
      @missing_checkouts_yesterday ||= AttendanceRecord
        .active
        .where(user_id: all_employee_ids, date: yesterday, status: "incomplete")
        .includes(:user)
        .to_a
    end

    def pending_requests_list
      @pending_requests_list ||= EmployeeRequest
        .pending
        .where(user_id: all_employee_ids)
        .includes(:user)
        .order(created_at: :asc)
        .to_a
    end

    # For trend: [user_id] pairs per date over the past 7 days (2 queries total).
    def week_checkins
      @week_checkins ||= AttendanceRecord
        .active
        .where(user_id: all_employee_ids, date: (today - 6.days)..today)
        .pluck(:date, :user_id)
        .group_by(&:first)
        .transform_values { |rows| rows.map(&:last).uniq }
    end

    # Shift assignments active at any point in the past 7 days.
    def week_assignments_raw
      @week_assignments_raw ||= ShiftAssignment
        .where(branch_id: branch_ids)
        .where("effective_from <= ?", today)
        .where("effective_to IS NULL OR effective_to >= ?", today - 6.days)
        .pluck(:user_id, :effective_from, :effective_to)
    end

    # ── Branch Health ──────────────────────────────────────────────────────────

    def branch_health
      @branch_health ||= begin
        records_by_branch  = today_records.group_by(&:branch_id)
        assigned_by_branch = Hash.new { |h, k| h[k] = [] }
        today_assignments.each { |uid, bid| assigned_by_branch[bid] << uid }

        # Map each employee to their branch for request aggregation.
        user_to_branch = {}
        employees_by_branch.each { |bid, uids| uids.each { |uid| user_to_branch[uid] = bid } }
        pending_by_branch = Hash.new(0)
        pending_requests_list.each { |r| pending_by_branch[user_to_branch[r.user_id]] += 1 }

        managed_branches.map do |branch|
          records       = records_by_branch[branch.id] || []
          assigned_uids = assigned_by_branch[branch.id].uniq
          total_emp     = (employees_by_branch[branch.id] || []).size

          present    = records.count { |r| AttendanceRecord::ATTENDED_STATUSES.include?(r.status) }
          incomplete = records.count { |r| r.status == "incomplete" }
          late       = records.count(&:counts_as_late?)
          checked_in = present + incomplete

          # Absent: had a shift today but no check-in at all.
          absent = (assigned_uids - records.map(&:user_id)).size

          att_pct = assigned_uids.empty? ? 0 : (checked_in * 100.0 / assigned_uids.size).round

          {
            branch:           branch,
            total_employees:  total_emp,
            assigned_today:   assigned_uids.size,
            present:          present,
            incomplete:       incomplete,
            checked_in:       checked_in,
            late:             late,
            absent:           absent,
            pending_requests: pending_by_branch[branch.id],
            att_pct:          att_pct,
            health:           derive_health(att_pct, absent, pending_by_branch[branch.id])
          }
        end
      end
    end

    def derive_health(att_pct, absent, pending)
      return :green  if att_pct >= 80 && absent == 0
      return :red    if att_pct < 60 || absent > 2
      :yellow
    end

    # ── Critical Alerts ────────────────────────────────────────────────────────

    def critical_alerts
      @critical_alerts ||= begin
        alerts = []

        # Absences: assigned today but no check-in.
        assigned_uids   = today_assignments.map(&:first).uniq
        checked_in_uids = today_records.map(&:user_id)
        absent_uids     = assigned_uids - checked_in_uids
        if absent_uids.any?
          alerts << {
            type:    :absences_today,
            count:   absent_uids.size,
            users:   User.where(id: absent_uids.first(5)).to_a
          }
        end

        # Missing punch-outs from yesterday.
        if missing_checkouts_yesterday.any?
          alerts << {
            type:    :missing_checkouts,
            count:   missing_checkouts_yesterday.size,
            records: missing_checkouts_yesterday.first(5)
          }
        end

        # Pending punch correction requests.
        corrections = pending_requests_list.select(&:punch_correction?)
        if corrections.any?
          alerts << {
            type:  :punch_corrections,
            count: corrections.size,
            items: corrections.first(5)
          }
        end

        # Coverage shortages: branches with < 60% attendance today.
        branch_health.select { |bh| bh[:att_pct] < 60 && bh[:assigned_today] > 0 }.each do |bh|
          alerts << {
            type:    :coverage_shortage,
            branch:  bh[:branch],
            att_pct: bh[:att_pct],
            absent:  bh[:absent]
          }
        end

        # Branches with no shift assignments today at all.
        assigned_branch_ids = today_assignments.map(&:last).uniq
        empty_branches = managed_branches.reject { |b| assigned_branch_ids.include?(b.id) }
        unless empty_branches.empty?
          alerts << { type: :no_assignments, branches: empty_branches }
        end

        alerts
      end
    end

    # ── Branch Ranking ─────────────────────────────────────────────────────────

    def branch_ranking
      branch_health.sort_by { |bh| -bh[:att_pct] }
    end

    # ── Pending Approvals ──────────────────────────────────────────────────────

    def pending_approvals
      by_type = pending_requests_list.group_by(&:request_type)
      {
        total:             pending_requests_list.size,
        punch_corrections: (by_type["punch_correction"] || []).size,
        late_permissions:  (by_type["late_permission"]  || []).size,
        early_leaves:      (by_type["early_leave"]       || []).size,
        salary_advances:   (by_type["salary_advance"]    || []).size,
        recent:            pending_requests_list.first(8)
      }
    end

    # ── Workforce Coverage ─────────────────────────────────────────────────────

    def workforce_coverage
      assigned_by_branch = Hash.new { |h, k| h[k] = [] }
      today_assignments.each { |uid, bid| assigned_by_branch[bid] << uid }

      managed_branches.map do |branch|
        assigned = assigned_by_branch[branch.id].uniq.size
        present  = today_records.count { |r|
          r.branch_id == branch.id && %w[present late early_leave incomplete].include?(r.status)
        }
        gap     = [assigned - present, 0].max
        surplus = [present - assigned, 0].max

        { branch: branch, assigned: assigned, present: present, gap: gap, surplus: surplus }
      end
    end

    # ── 7-Day Attendance Trend ─────────────────────────────────────────────────

    def attendance_trend
      7.times.map { |i| today - i.days }.reverse.map do |date|
        assigned = week_assignments_raw
          .count { |_uid, ef, et| ef <= date && (et.nil? || et >= date) }

        # Unique employees who checked in on this date (regardless of status).
        present = (week_checkins[date] || []).size

        pct = assigned.zero? ? 0 : (present * 100.0 / assigned).round

        { date: date, present: present, assigned: assigned, pct: pct }
      end
    end

    # ── Stats strip ────────────────────────────────────────────────────────────

    def stats
      checked_in = today_records.size
      assigned   = today_assignments.map(&:first).uniq.size
      absent     = [assigned - checked_in, 0].max

      {
        branch_count:      managed_branches.size,
        total_employees:   all_employee_ids.size,
        checked_in_today:  checked_in,
        absent_today:      absent,
        pending_requests:  pending_requests_list.size,
        missing_checkouts: missing_checkouts_yesterday.size,
        critical_count:    critical_alerts.size
      }
    end
  end
end
