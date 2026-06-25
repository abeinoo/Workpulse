module Finance
  # Creates the next link in a branch's till handover chain.
  #
  # Rules enforced here (beyond DB constraints):
  #   - Only the current tail-holder may create the next handover.
  #   - Only one chain head may exist per branch per day (DB partial unique index).
  #   - Depositor-type handovers are immediately self-accepted.
  #   - Lines are built from the submitted amounts hash keyed by payment_method_id.
  class TillHandoverCreator
    include AuditLoggable

    Result = Struct.new(:ok, :handover, :error, keyword_init: true) { def ok? = ok }

    def initialize(actor:, branch:, business_date:, params:)
      @actor         = actor
      @branch        = branch
      @business_date = business_date
      @params        = params
    end

    def call
      ActiveRecord::Base.transaction do
        validate_actor_is_current_holder!

        handover = build_handover
        handover.save!
        build_lines(handover)
        audit_handover(handover)

        Result.new(ok: true, handover: handover)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    rescue ArgumentError => e
      Result.new(ok: false, error: e.message)
    end

    private

    def validate_actor_is_current_holder!
      current = TillHandover.current_holder_for(@branch, @business_date)

      if current.nil?
        # First handover of the day — actor must be starting from scratch.
        return
      end

      unless current.from_user_id == @actor.id
        raise ArgumentError, I18n.t("till_handovers.errors.not_current_holder")
      end
    end

    def build_handover
      previous = TillHandover
                   .for_branch_date(@branch, @business_date)
                   .accepted
                   .where.missing(:next_handover)
                   .first

      type = @params[:handover_type].to_s

      handover = TillHandover.new(
        business:             @branch.business,
        branch:               @branch,
        business_date:        @business_date,
        from_user:            @actor,
        to_user_id:           type == "transfer" ? @params[:to_user_id] : nil,
        handover_type:        type,
        previous_handover:    previous,
        notes:                @params[:notes]
      )

      # Depositor declares custody immediately — no separate accept step.
      handover.accepted_at = Time.current if handover.depositor?
      handover
    end

    def build_lines(handover)
      amounts = @params[:lines] || {}
      amounts.each do |payment_method_id, attrs|
        handover.lines.create!(
          payment_method_id: payment_method_id,
          collected_amount:  attrs[:collected_amount].to_d,
          refund_amount:     attrs[:refund_amount].to_d
        )
      end
    end

    def audit_handover(handover)
      log_audit(
        actor:     @actor,
        auditable: handover,
        action:    "create",
        metadata:  { handover_type: handover.handover_type,
                     business_date: handover.business_date.to_s }
      )
    end
  end
end
