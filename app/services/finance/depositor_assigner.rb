module Finance
  # Directly moves a DailyReconciliation's deposit responsibility
  # (TillSession#depositor) to another eligible employee, bypassing the
  # DepositResponsibilityTransfer accept workflow. Used only by the Bank
  # Dispute depositor-mismatch fix (reassign to the employee who actually put
  # the cash in the ATM). The DR page's "Transfer Deposit Responsibility"
  # action does NOT come here — it requests a pending transfer the recipient
  # must accept (Finance::DepositResponsibilityTransferRequester).
  #
  # Changes ONLY till_session.depositor_id. Amounts, deposits (and their
  # deposited_by), handovers, POS/sales data, RemainingDepositBalances and the
  # DR's state/date are never touched.
  #
  # History: each reassignment appends an "assign_depositor" AuditLog on the DR
  # carrying previous/new depositor, the actor and optional notes. That row is
  # the transfer's only record, so unlike most log_audit calls a failed write
  # rolls the reassignment back instead of being swallowed.
  #
  # Concurrency: runs under the DR row lock (the same lock TillDepositRecorder
  # takes), and every guard is evaluated against the locked, freshly read
  # state. expected_depositor_id is optional; when given (the transfer form
  # sends the depositor it displayed), the call is rejected if responsibility
  # has moved since — the server's current depositor is always what's used.
  class DepositorAssigner
    include AuditLoggable

    NOTES_MAX_LENGTH = 500

    Result = Struct.new(:ok, :error, :depositor, :previous_depositor, keyword_init: true) { def ok? = ok }

    def initialize(daily_reconciliation_id, actor:, depositor_id:, expected_depositor_id: nil, notes: nil)
      @dr_id                 = daily_reconciliation_id
      @actor                 = actor
      @depositor_id          = depositor_id.to_i
      @expected_depositor_id = expected_depositor_id.presence&.to_i
      @notes                 = notes.to_s.strip.presence
    end

    def call
      @dr = DailyReconciliation.where(business_id: @actor.business_id).find(@dr_id)

      if @notes && @notes.length > NOTES_MAX_LENGTH
        return failure(:deposit_transfer_notes_too_long, count: NOTES_MAX_LENGTH)
      end

      depositor = @actor.business.users.includes(:permission_role).find_by(id: @depositor_id)
      return failure(:invalid_depositor) unless depositor
      return failure(:deposit_transfer_ineligible, name: depositor.full_name) unless depositor.eligible_depositor?

      previous = nil
      ActiveRecord::Base.transaction do
        @dr.lock!
        session = @dr.till_session
        raise ArgumentError, error_text(:deposit_transfer_not_allowed) unless @dr.deposit_responsibility_transferable?
        raise ArgumentError, error_text(:pending_transfer_exists) if @dr.deposit_responsibility_transfers.pending.exists?

        previous = session.depositor
        if @expected_depositor_id && previous&.id != @expected_depositor_id
          raise ArgumentError, error_text(:deposit_transfer_stale, name: previous&.full_name || "—")
        end
        raise ArgumentError, error_text(:deposit_transfer_same_depositor, name: depositor.full_name) if previous == depositor

        session.update!(depositor: depositor)

        log_audit!(
          actor: @actor, auditable: @dr, action: "assign_depositor",
          changes:  { depositor_id: [ previous&.id, depositor.id ] },
          metadata: {
            depositor_id:            depositor.id,
            depositor_name:          depositor.full_name,
            previous_depositor_id:   previous&.id,
            previous_depositor_name: previous&.full_name,
            notes:                   @notes
          }.compact
        )
      end

      Result.new(ok: true, depositor: depositor, previous_depositor: previous)
    rescue ArgumentError => e
      Result.new(ok: false, error: e.message)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      Result.new(ok: false, error: error_text(:deposit_transfer_audit_failed))
    end

    private

    def error_text(key, **opts) = I18n.t("finance.daily_reconciliations.errors.#{key}", **opts)

    def failure(key, **opts) = Result.new(ok: false, error: error_text(key, **opts))
  end
end
