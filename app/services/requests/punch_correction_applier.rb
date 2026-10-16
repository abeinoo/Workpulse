module Requests
  # Applies an approved PunchCorrection request (Workforce side).
  #
  # The attendance and payroll effect — the punch write, the recomputation and
  # the payroll lines — is Attendance & Payroll's, reached only through the
  # Workforce contract Requests::PunchCorrectionEffects.correction_approved
  # (Pilot 10 M4-2). This class keeps what Workforce owns:
  #   - the moment applied (the request's final punch, see effective_punch_at);
  #   - the snapshot of the replaced punches (check_in_at / check_out_at and
  #     their sources), persisted onto the request from the contract's result so
  #     cancellation can restore the pre-correction state;
  #   - the user-facing message for each refusal.
  #
  # Everything runs inside one transaction (the approver's, when called from
  # Requests::Approver), so a failure leaves the request, the attendance record
  # and payroll in their original state. A refusal is decided before anything
  # is written.
  class PunchCorrectionApplier
    # approval — the contract's Approval (plain values) on success.
    Result = Struct.new(:success, :approval, :error, keyword_init: true) do
      def success? = success
    end

    # actor — the reviewer the correction is applied for (defaults to the
    # request's saved reviewer).
    def self.call(request:, actor: request.reviewed_by)
      new(request, actor: actor).call
    end

    # The exact moment a correction applies: the final punch date + "HH:MM" in
    # the business timezone, taken literally — never shifted across midnight.
    # Defaults to the request's final punch (reviewer-selected date/time, else
    # the employee's proposal). Public so the pre-approval attendance-window and
    # duration checks judge the same datetime the applier writes.
    def self.effective_punch_at(request:, date: nil, time_str: nil)
      new(request).effective_punch_at(date: date || request.final_punch_date,
                                      time_str: time_str.presence || request.final_punch_time)
    end

    # What a correction approved BEFORE reviewer-selected dates existed
    # (approved_punch_at nil) actually wrote: the proposal rolled ±1 day against the
    # record's other punch. Used only to display those historical approvals
    # faithfully — new approvals never roll.
    def self.legacy_applied_punch_at(request:, check_in_at:, check_out_at:)
      new(request).legacy_applied_punch_at(check_in_at: check_in_at, check_out_at: check_out_at)
    end

    def initialize(request, actor: request.reviewed_by)
      @request = request
      @actor   = actor
    end

    def call
      effective_at = self.class.effective_punch_at(request: @request)
      approval     = nil

      ActiveRecord::Base.transaction do
        approval = PunchCorrectionEffects.correction_approved(
          request: @request, field: @request.correction_field, effective_at: effective_at, actor: @actor
        )
        persist_snapshot(approval.snapshot) if approval.applied?
      end

      return failure(refusal_message(approval.status)) if approval.refused?

      Result.new(success: true, approval: approval)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.join(", "))
    rescue => e
      failure(e.message)
    end

    def effective_punch_at(date:, time_str:)
      build_datetime(date, time_str)
    end

    def legacy_applied_punch_at(check_in_at:, check_out_at:)
      dt = build_datetime(@request.proposed_punch_date, @request.final_punch_time)
      case @request.correction_field
      when :check_in  then resolve_check_in(dt, check_out_at)
      when :check_out then resolve_check_out(dt, check_in_at)
      end
    end

    private

    # The punches the correction replaced, persisted onto the request exactly as
    # before M4-2 (update_columns: no validations, callbacks or updated_at).
    def persist_snapshot(snapshot)
      @request.update_columns(
        original_check_in_at:      snapshot.check_in_at,
        original_check_out_at:     snapshot.check_out_at,
        original_check_in_source:  snapshot.check_in_source,
        original_check_out_source: snapshot.check_out_source
      )
    end

    # The contract's refusals as the messages approval has always shown. The
    # no-record message is the historical literal (not translated).
    def refusal_message(status)
      case status
      when :no_attendance_record then "No attendance record found for #{@request.requested_for_date}"
      # A finalized / paid payroll period is frozen: correcting its attendance
      # would leave attendance and payroll permanently out of step.
      when :payroll_locked then I18n.t("requests.errors.cannot_approve_finalized")
      else I18n.t("requests.errors.#{status}")
      end
    end

    # Combines the punch's actual calendar date (not the work/business date) with
    # an "HH:MM" string in the business timezone. Overnight punches carry their
    # real date — e.g. a check-out at 04:00 for the previous day's shift is dated
    # the next calendar day by the employee or the reviewer.
    def build_datetime(date, time_str)
      return nil if date.nil? || time_str.blank?

      hours, minutes = time_str.to_s.split(":").first(2).map(&:to_i)
      tz = ActiveSupport::TimeZone[@request.user.business.timezone]
      tz.local(date.year, date.month, date.day, hours, minutes, 0)
    end

    # Legacy only (see legacy_applied_punch_at): the ±1-day roll that approvals
    # made before reviewer-selected dates existed. Rolled a check-out that fell
    # before the check-in forward one day.
    def resolve_check_out(check_out_dt, existing_check_in)
      return check_out_dt if check_out_dt.nil? || existing_check_in.nil?

      check_out_dt < existing_check_in ? check_out_dt + 1.day : check_out_dt
    end

    # Legacy only: the symmetric roll of a check-in past the check-out back one day.
    def resolve_check_in(check_in_dt, existing_check_out)
      return check_in_dt if check_in_dt.nil? || existing_check_out.nil?

      check_in_dt > existing_check_out ? check_in_dt - 1.day : check_in_dt
    end

    def failure(message)
      Result.new(success: false, error: message)
    end
  end
end
