module Employee
  # The single writer of employee attendance requirement history rows (R3.2 G5;
  # attendance plan revision 19, §6.1, §19.14, OD-3 … OD-12).
  #
  #   source :creation   the first row of a new employee (G6 callers): no reason,
  #                      no D4 check (OD-7); the employee must have no row yet
  #   source :hr_change  a later change of an existing timeline: refused while
  #                      the rollout switch is off (OD-5)
  #
  # Inside ONE transaction, in this order (§19.14):
  #   1. the per-employee advisory lock (L3, OD-3) — first lock
  #   2. validation: required / not_required only (never not_reviewed); a real
  #      change; to not_required no assignment of any kind active on or after the
  #      effective date (A5); a backdated hr_change needs a reason and must touch
  #      no payroll period of the business that is under review or later (D4,
  #      OD-10) — asked through Employee::PayrollDateProtection, which takes the
  #      payroll-status lock (shared) and the period row locks (OD-12)
  #   3. the history row, then log_audit (old, new, effective date, reason)
  # Any refusal or error rolls everything back: no row, no audit entry. The
  # rejected-attempt audit is R3.4.
  #
  # "Today" is the business day. Every refusal is a Result with an error key
  # and, for a protected payroll period, the period and stage.
  class AttendanceRequirementChanger
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, :details, keyword_init: true) { def ok? = ok }

    SOURCES  = %w[creation hr_change].freeze
    STATUSES = %w[required not_required].freeze

    class Refused < StandardError
      attr_reader :key, :details

      def initialize(key, details = {})
        @key = key
        @details = details
        super(key.to_s)
      end
    end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(user_id:, status:, effective_from:, actor:, source:, reason: nil)
      @user_id        = user_id
      @status         = status.to_s
      @effective_from = effective_from
      @actor          = actor
      @source         = source.to_s
      @reason         = reason.to_s.strip.presence
    end

    def call
      employee = User.where(business_id: @actor.business_id).find(@user_id)
      record = nil
      EmployeeAttendanceRequirement.transaction do
        authorise!(employee)
        AttendanceRequirements.lock_employee!(user_id: employee.id)
        old_status = validate!(employee)
        record = EmployeeAttendanceRequirement.create!(
          business_id: employee.business_id, user: employee, status: @status, effective_from: @effective_from,
          source: @source, reason: @reason, changed_by: @actor
        )
        log_audit(actor: @actor, auditable: employee, action: "attendance_requirement_changed",
                  changes: { status: [ old_status.to_s, @status ] },
                  metadata: { effective_from: @effective_from.iso8601, reason: @reason, backdated: backdated?,
                              source: @source, requirement_id: record.id })
      end
      Result.new(ok: true, record: record)
    rescue Refused => e
      Result.new(ok: false, error: e.key, details: e.details)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, record: e.record, error: :invalid)
    end

    private

    def authorise!(employee)
      raise Refused, :invalid_source unless SOURCES.include?(@source)

      if @source == "creation"
        raise Refused, :not_authorized unless UserPolicy.new(@actor, employee).create?
      else
        raise Refused, :rollout_inactive unless Workforce::AttendanceRequirementRollout.active?(@actor.business)
        raise Refused, :not_authorized unless UserPolicy.new(@actor, employee).change_attendance_requirement?
      end
    end

    def validate!(employee)
      raise Refused, :invalid_status unless STATUSES.include?(@status)
      raise Refused, :effective_date_required unless @effective_from.is_a?(Date)

      validate_timeline!(employee)
      validate_assignments!(employee) if @status == "not_required"
      validate_backdating!(employee) if @source == "hr_change" && backdated?
      AttendanceRequirements.status_on(user_id: employee.id, date: @effective_from)
    end

    def validate_timeline!(employee)
      if @source == "creation"
        raise Refused, :already_recorded if AttendanceRequirements.timeline(user_id: employee.id).exists?
      elsif AttendanceRequirements.status_on(user_id: employee.id, date: @effective_from).to_s == @status
        raise Refused, :unchanged
      end
    end

    # A5: future assignments must be ended or cancelled first; open-ended ones
    # must end before the effective date. Explicit dates, never the server date.
    def validate_assignments!(employee)
      active = ShiftAssignment.where(user_id: employee.id)
                              .where("effective_to IS NULL OR effective_to >= ?", @effective_from)
      raise Refused, :assignments_active if active.exists?
    end

    def validate_backdating!(employee)
      raise Refused, :reason_required if @reason.blank?

      protected_period = PayrollDateProtection.lock_protected_range(
        business_id: employee.business_id, from: @effective_from, through: today - 1
      )
      return unless protected_period

      raise Refused.new(:payroll_protected, starts_on: protected_period.starts_on, stage: protected_period.stage)
    end

    def backdated? = @effective_from < today

    def today = @today ||= AttendanceRequirements.today(@actor.business)
  end
end
