module Finance
  # A manager asks to move a DailyReconciliation's deposit responsibility to
  # another eligible employee ("Transfer Deposit Responsibility" on the DR
  # page). Creates a *pending* DepositResponsibilityTransfer — the same record
  # the Day Close flow creates — and changes nothing else: the current
  # depositor stays responsible until the recipient accepts
  # (DepositResponsibilityTransferAcceptor) or rejects
  # (DepositResponsibilityTransferRejecter).
  #
  # Concurrency: runs under the DR row lock shared by every depositor-changing
  # service and TillDepositRecorder; all guards are evaluated against the
  # locked state. expected_depositor_id (the depositor the form displayed) is
  # only a precondition — from_user is always the server's current depositor.
  class DepositResponsibilityTransferRequester
    include AuditLoggable

    NOTES_MAX_LENGTH = 500

    Result = Struct.new(:ok, :error, :transfer, keyword_init: true) { def ok? = ok }

    def initialize(daily_reconciliation_id, actor:, to_user_id:, expected_depositor_id: nil, notes: nil)
      @dr_id                 = daily_reconciliation_id
      @actor                 = actor
      @to_user_id            = to_user_id.to_i
      @expected_depositor_id = expected_depositor_id.presence&.to_i
      @notes                 = notes.to_s.strip.presence
    end

    def call
      @dr = DailyReconciliation.where(business_id: @actor.business_id).find(@dr_id)

      if @notes && @notes.length > NOTES_MAX_LENGTH
        return failure(:deposit_transfer_notes_too_long, count: NOTES_MAX_LENGTH)
      end

      recipient = @actor.business.users.includes(:permission_role).find_by(id: @to_user_id)
      return failure(:invalid_depositor) unless recipient
      return failure(:deposit_transfer_self) if recipient == @actor
      return failure(:deposit_transfer_ineligible, name: recipient.full_name) unless recipient.eligible_depositor?

      transfer = nil
      ActiveRecord::Base.transaction do
        @dr.lock!
        raise ArgumentError, error_text(:deposit_transfer_not_allowed) unless @dr.deposit_responsibility_transferable?
        raise ArgumentError, error_text(:deposit_transfer_already_pending) if @dr.deposit_responsibility_transfers.pending.exists?

        current = @dr.till_session.depositor
        if @expected_depositor_id && current.id != @expected_depositor_id
          raise ArgumentError, error_text(:deposit_transfer_stale, name: current.full_name)
        end
        raise ArgumentError, error_text(:deposit_transfer_same_depositor, name: recipient.full_name) if current == recipient

        transfer = DepositResponsibilityTransfer.create!(
          daily_reconciliation: @dr,
          from_user:            current,
          to_user:              recipient,
          initiated_by:         @actor,
          notes:                @notes
        )

        # The transfer row is the request's record; this audit entry is part
        # of the same all-or-nothing step, so a failed write rolls it back.
        logged = log_audit(
          actor: @actor, auditable: transfer, action: "request",
          metadata: { daily_reconciliation_id: @dr.id, from_user_id: current.id,
                      to_user_id: recipient.id, notes: @notes }.compact
        )
        raise ArgumentError, error_text(:deposit_transfer_audit_failed) unless logged
      end

      Result.new(ok: true, transfer: transfer)
    rescue ArgumentError => e
      Result.new(ok: false, error: e.message)
    rescue ActiveRecord::RecordNotUnique
      failure(:deposit_transfer_already_pending)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def error_text(key, **opts) = I18n.t("finance.daily_reconciliations.errors.#{key}", **opts)

    def failure(key, **opts) = Result.new(ok: false, error: error_text(key, **opts))
  end
end
