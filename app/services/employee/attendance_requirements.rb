module Employee
  # The Workforce read API of the attendance requirement history (R3.2; roadmap
  # revision 19, §2 W, §6.2) and the per-employee lock every writer takes.
  #
  # The requirement in force on a date is DERIVED ON READ (OD-4): the latest
  # history row with effective_from on or before the date, rows of one date
  # ordered by id (OD-15 T3). There is no cache column and no job. An employee
  # with no row on a date — before their first row, or on the HR exception
  # list — is :not_reviewed (L25), never :not_required.
  #
  # "Today" is the business day (BusinessDay.current), never the server date.
  module AttendanceRequirements
    STATUSES = %i[required not_required not_reviewed].freeze

    # Advisory lock namespace for one employee's requirement changes (L3,
    # OD-3): pg_advisory_xact_lock(LOCK_NAMESPACE, user_id). Not a users row
    # lock. Distinct from every other namespace in app/ ("EA").
    LOCK_NAMESPACE = 0x4541

    class LockOutsideTransaction < StandardError; end

    module_function

    # :required / :not_required / :not_reviewed in force on `date` for the
    # employee — one indexed query.
    def status_on(user_id:, date:)
      row = row_on(user_id: user_id, date: date)
      row ? row.status.to_sym : :not_reviewed
    end

    # The history row in force on `date`, or nil.
    def row_on(user_id:, date:)
      EmployeeAttendanceRequirement.where(user_id: user_id)
                                   .where(effective_from: ..date)
                                   .order(effective_from: :desc, id: :desc)
                                   .first
    end

    # Every row of the employee, oldest first (same-date rows by id).
    def timeline(user_id:)
      EmployeeAttendanceRequirement.where(user_id: user_id).in_timeline_order
    end

    # The row in force on `date` (default: the business's business day) for
    # each employee of the business that has one — a relation for lists and
    # reports. Employees absent from it have no row: :not_reviewed.
    def in_force_scope(business:, date: today(business))
      in_force_ids = EmployeeAttendanceRequirement
                     .where(business_id: business.id, effective_from: ..date)
                     .select("DISTINCT ON (user_id) id")
                     .order(:user_id, effective_from: :desc, id: :desc)
      EmployeeAttendanceRequirement.where(id: in_force_ids)
    end

    def today(business) = BusinessDay.current(context: business)

    # Serialises every change of one employee's requirement (and, from R3.4,
    # of the daily-paid invariant) until the surrounding transaction ends.
    # Must be the first lock of the writer's transaction; different employees
    # never wait for each other (OD-11).
    def lock_employee!(user_id:)
      connection = EmployeeAttendanceRequirement.connection
      raise LockOutsideTransaction, "lock_employee! needs an open transaction" unless connection.transaction_open?

      connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{Integer(user_id)})")
    end
  end
end
