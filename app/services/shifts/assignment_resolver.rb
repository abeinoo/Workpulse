module Shifts
  # Single source of truth for "which ShiftAssignment (and therefore which
  # branch) applies to this user on this date" — replaces Shifts::AssignmentFinder.
  #
  # A user can legitimately hold more than one concurrent, active
  # ShiftAssignment (e.g. their regular assignment plus a temporary_coverage
  # assignment at a different branch — see ShiftAssignment#no_overlapping_shift_time
  # for why these are allowed to clock-overlap). Every caller that needs to
  # pick exactly ONE branch for a user "right now" — attendance check-in,
  # which Daily Reconciliation a cashier's till actions target, form
  # defaults — must resolve through here rather than taking `.current.first`
  # off an unordered scope, which is arbitrary once more than one assignment
  # is active.
  #
  # Priority: an active temporary_coverage assignment always wins over a
  # concurrent regular one (coverage is deliberately more specific/intentional
  # than the baseline assignment it's superseding). Among assignments of the
  # same kind, the most recently started (effective_from) wins, with id as a
  # final stable tie-break.
  class AssignmentResolver
    # Resolves the single winning assignment for one user.
    #
    # branch:, when given, narrows to assignments at that branch only (used
    # by attendance's mobile check-in, which already knows the branch and
    # just wants to confirm/find the matching assignment).
    #
    # time:, when given, prefers a candidate whose shift's fixed clock window
    # actually contains that time — falls back to the full candidate pool if
    # none match (e.g. every active assignment is hour_based, which has no
    # fixed window to test against).
    def self.for(user:, date: Date.current, branch: nil, time: nil)
      scope = ShiftAssignment.includes(:shift, :branch).where(user: user).active_on(date)
      scope = scope.where(branch: branch) if branch
      pick_best(scope.to_a, time: time)
    end

    # Batch variant — ONE query for many users, returning { user_id =>
    # winning ShiftAssignment (or nil) }. The batch-safe primitive for any
    # caller resolving many employees' effective branch for the same date
    # (e.g. a report or dashboard) — avoids issuing .for per employee.
    def self.for_many(users:, date: Date.current)
      user_ids = users.map { |u| u.is_a?(ActiveRecord::Base) ? u.id : u }
      by_user  = ShiftAssignment.includes(:shift, :branch)
                                 .where(user_id: user_ids)
                                 .active_on(date)
                                 .group_by(&:user_id)

      user_ids.index_with { |uid| pick_best(by_user[uid] || [], time: nil) }
    end

    def self.pick_best(candidates, time:)
      return candidates.first if candidates.size <= 1

      pool = candidates
      if time
        time_matched = candidates.select { |a| shift_covers_time?(a.shift, time) }
        pool = time_matched if time_matched.any?
      end

      pool.min_by { |a| [ a.temporary_coverage? ? 0 : 1, -a.effective_from.to_time.to_i, -a.id ] }
    end
    private_class_method :pick_best

    # True when `time` falls within the shift's fixed clock window. Shifts
    # with no fixed window (hour_based) are always considered a match — there
    # is nothing to exclude them on.
    def self.shift_covers_time?(shift, time)
      return true unless shift&.fixed_time? && shift.start_time && shift.end_time

      t  = time.hour * 60 + time.min
      s  = shift.start_time.hour * 60 + shift.start_time.min
      e  = shift.end_time.hour   * 60 + shift.end_time.min
      e += 1440 if e <= s # overnight shift: push end past midnight

      (s...e).cover?(t) || (s...e).cover?(t + 1440)
    end
    private_class_method :shift_covers_time?
  end
end
