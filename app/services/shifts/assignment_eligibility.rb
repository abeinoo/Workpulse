module Shifts
  # Single source of truth for "is this employee available for a new regular
  # ShiftAssignment?" — used both to populate the Assign Shift employee picker
  # and to reject ineligible submissions server-side.
  #
  # Only shift-based employees are ever eligible: users.requires_shift_assignment
  # must be set (unticked for remote staff and roles that don't work shifts),
  # and the business owner is never a shift worker. Having no active assignment
  # does not by itself make someone available.
  #
  # A shift-based employee is eligible when none of their assignments active
  # today would still be running beyond the availability window:
  #
  #   no active assignment (never assigned, or previous one ended) → available now
  #   active, effective_to <= today + window (incl. ending today)  → available soon
  #   active, effective_to beyond the window                      → not eligible
  #   active, effective_to NULL (open-ended / ongoing)             → not eligible
  #
  # The branch of the active assignment does not matter — an employee ending
  # soon at another branch is eligible (e.g. a transfer being prepared).
  # Future-dated (upcoming) assignments are not "active" and are left to
  # ShiftAssignment's own overlap validations.
  #
  # "Today" is the business's local date, never the server's.
  class AssignmentEligibility
    Candidate = Struct.new(:user, :status, :branch_name, :ends_on, keyword_init: true) do
      def available_now?  = status == :available_now
      def available_soon? = status == :available_soon
    end

    attr_reader :today, :window_days

    def initialize(business:, today: nil, window_days: ShiftAssignment::AVAILABILITY_WINDOW_DAYS)
      @business    = business
      @today       = today || business.timezone_object.today
      @window_days = window_days
    end

    def window_end
      today + window_days
    end

    # Assignments that keep their employee unavailable: active today and not
    # ending within the window (open-ended assignments included).
    def blocking_assignments
      ShiftAssignment.active_on(today)
                     .where("effective_to IS NULL OR effective_to > ?", window_end)
    end

    # Narrows a User relation to employees who work shifts at all.
    def shift_based(pool)
      pool.where(requires_shift_assignment: true).where.not(id: @business.owner_id)
    end

    # Narrows a User relation to the employees eligible for a new assignment.
    def eligible_users(pool)
      shift_based(pool).where.not(id: blocking_assignments.select(:user_id))
    end

    def eligible?(user_id)
      eligible_users(@business.users).exists?(id: user_id)
    end

    # Eligible employees from `pool` as Candidates — available now first, then
    # available soon — each carrying the current branch (as resolved by
    # AssignmentResolver) and the date their last active assignment ends.
    # A fixed number of queries regardless of pool size.
    def candidates(pool)
      users   = eligible_users(pool).order(:first_name, :last_name).to_a
      current = AssignmentResolver.for_many(users: users, date: today)
      ends_on = ShiftAssignment.active_on(today)
                               .where(user_id: users.map(&:id))
                               .group(:user_id)
                               .maximum(:effective_to)

      list = users.map do |user|
        assignment = current[user.id]
        next Candidate.new(user: user, status: :available_now) if assignment.nil?

        Candidate.new(
          user:        user,
          status:      :available_soon,
          branch_name: assignment.branch_name,
          ends_on:     ends_on[user.id]
        )
      end

      list.partition(&:available_now?).flatten
    end
  end
end
