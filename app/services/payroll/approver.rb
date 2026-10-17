module Payroll
  # Advances a PayrollPeriod through its status machine.
  #
  # Normal path (auto-driven):
  #   draft → under_review            (via SubmitForReview)
  #   under_review → branch_review_completed  (via BranchReviewCompleter, once all branches done)
  #
  # Super admin path (this service):
  #   branch_review_completed → finalized   (normal final approval)
  #   under_review → finalized              (override: skip branch review)
  #   finalized → paid                      (settle advances)
  class Approver
    TRANSITIONS = {
      "branch_review_completed" => "finalized",
      "under_review"            => "finalized",  # super-admin override
      "finalized"               => "paid"
    }.freeze

    Result = Struct.new(:success, :period, :error, keyword_init: true) do
      def success? = success
    end

    def self.advance(period:, by:)
      new(period: period, by: by).advance
    end

    def initialize(period:, by:)
      @period = period
      @by     = by
    end

    def advance
      observed_status = @period.status
      next_status     = TRANSITIONS[observed_status]
      return err(no_transition_error) unless next_status

      transition_error = nil

      ActiveRecord::Base.transaction do
        # Lock the period row before acting (the same row a punch-correction
        # approval / cancellation locks for its period check — Pilot 10 M4-2), so
        # finalizing or paying waits for an in-flight correction and then sees the
        # committed status. The transition the caller asked for applies only to
        # the status it saw: a concurrent transition is neither repeated nor
        # turned into the next one.
        @period.lock!
        unless @period.status == observed_status
          transition_error = no_transition_error
          raise ActiveRecord::Rollback
        end

        case next_status
        when "finalized"
          from = @period.status
          @period.update!(status: "finalized", finalized_by: @by, finalized_at: Time.current)
          PayrollAuditLog.create!(
            payroll_period: @period,
            actor:          @by,
            action_type:    :finalized,
            from_status:    from,
            to_status:      "finalized"
          )
          # Finance effects of finalization (the Social Insurance expense) go
          # through the Payroll-defined contract, inside this transaction. The
          # employer insurance cost is computed here, from payroll's own data.
          insurance = Payroll::EmployerInsuranceCost.for(@period)
          Payroll::FinalizationEffects.period_finalized(
            period: @period, actor: @by,
            employer_insurance_total: insurance.total, employer_insurance_by_branch: insurance.by_branch
          )
        when "paid"
          settle_advances!
          @period.update!(status: "paid")
          PayrollAuditLog.create!(
            payroll_period: @period,
            actor:          @by,
            action_type:    :paid,
            from_status:    "finalized",
            to_status:      "paid"
          )
        end
      end

      return err(transition_error) if transition_error

      Result.new(success: true, period: @period)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    rescue StandardError => e
      err(e.message)
    end

    private

    def settle_advances!
      @period.payroll_entries.includes(:payroll_line_items).each do |entry|
        entry.payroll_line_items.advance_deduction.each do |li|
          advance = Advance.find_by(id: li.source_id)
          advance&.repay!(li.amount.abs)
        end
      end
    end

    def no_transition_error = "No transition available from '#{@period.status}'"

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
