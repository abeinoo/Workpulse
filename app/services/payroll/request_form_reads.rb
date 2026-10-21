module Payroll
  # Attendance & Payroll implementation of the Workforce Requests::RequestFormReads
  # contract (registered in config/initializers/request_form_reads.rb): what the
  # employee-request form, show page, validation and policy read from Attendance &
  # Payroll (Batch V — request-validation reads, D-A5).
  #
  # Each operation is the code it replaces, unchanged:
  #   advance_limit / advance_limit_for — EmployeeRequest#within_advance_limit and
  #     EmployeeRequestsController#advance_limit_for (Salary::AdvanceEligibilityCalculator,
  #     SalaryProfilePolicy#view_salary?, Salary::ViewAudit);
  #   salary_visible?  — EmployeeRequestPolicy#create? (SalaryProfilePolicy.viewable_employees);
  #   attendance_day   — EmployeeRequestsController#show (AttendanceRecord.find_by);
  #   recent_check_ins — EmployeeRequestsController#punch_check_ins_for;
  #   duration_threshold_hours — Attendance::DurationCheck.threshold_hours in the
  #     request show page and its resulting-duration panel.
  module RequestFormReads
    module_function

    def advance_limit(user:)
      to_limit(Salary::AdvanceEligibilityCalculator.for(user: user))
    end

    # The visibility decision is SalaryProfilePolicy#view_salary? on a profile of
    # the employee, as the form always used it (equivalent to salary_visible? for
    # another employee; kept separate, not consolidated).
    def advance_limit_for(user:, viewer:)
      result = Salary::AdvanceEligibilityCalculator.for(user: user)
      return view(result) if result.nil? || user == viewer

      unless SalaryProfilePolicy.new(viewer, SalaryProfile.new(user_id: user.id)).view_salary?
        return Requests::RequestFormReads::AdvanceLimitView.new(limit: nil, hidden: true)
      end

      unless result.no_profile?
        Salary::ViewAudit.record(actor: viewer, employee: user,
                                 profiles: [ SalaryProfile.current_for(user) ], source: "request_advance_limit")
      end
      view(result)
    end

    def salary_visible?(viewer:, employee:)
      SalaryProfilePolicy.viewable_employees(viewer).exists?(id: employee.id)
    end

    def attendance_day(user:, date:)
      record = AttendanceRecord.find_by(user: user, work_date: date)
      return unless record

      Requests::RequestFormReads::AttendanceDay.new(
        check_in_at:       record.check_in_at,
        check_out_at:      record.check_out_at,
        status:            record.status,
        worked_minutes:    record.worked_minutes,
        duration_severity: record.duration_severity
      )
    end

    def recent_check_ins(user:)
      tz = user.business.timezone_object
      AttendanceRecord.where(user: user, work_date: (Date.current - Requests::RequestFormReads::RECENT_CHECK_INS_DAYS.days)..)
                      .where.not(check_in_at: nil)
                      .pluck(:work_date, :check_in_at)
                      .to_h { |date, at| [ date.iso8601, at.in_time_zone(tz).strftime("%Y-%m-%dT%H:%M") ] }
    end

    def duration_threshold_hours(severity:, business:)
      Attendance::DurationCheck.threshold_hours(severity, business: business)
    end

    def view(result) = Requests::RequestFormReads::AdvanceLimitView.new(limit: to_limit(result), hidden: false)

    def to_limit(result)
      return if result.nil?

      Requests::RequestFormReads::AdvanceLimit.new(
        description_key: result.description_key,
        max_amount:      result.max_amount,
        outstanding:     result.outstanding,
        available:       result.available,
        no_profile:      result.no_profile
      )
    end

    private_class_method :view, :to_limit
  end
end
