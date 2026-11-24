module Inventory
  # Records an advance that FUNDS the Purchase Request's responsible employee's
  # custody (PurchaseRequestAdvance#funding?) and posts that funding at once, in
  # one transaction — there is no second-person confirmation. The advance is
  # saved "confirmed" (confirmed_by / confirmed_at = the recorder, now) together
  # with its custody rows, posted by Finance & Sales through
  # Inventory::PurchaseRequestAdvanceEffects.advance_funded:
  #   - employee_custody: a linked "transfer" pair — the source employee's
  #     custody −amount, the responsible employee's +amount;
  #   - company_cash / bank_account: one "purchase_advance_funding" credit on the
  #     responsible employee's custody (no company cash/bank ledger — BUG-049).
  # Never a supplier payment (no FinancialSettlement). If any step fails or is
  # refused, nothing is written: no advance, no custody row, no audit entry.
  # Reversal and the cancellation of advances still pending from the old
  # two-step workflow: Inventory::PurchaseRequestAdvanceWorkflow.
  #
  # Server-side rules (the form is never trusted):
  #   - the request must belong to the actor's business and be receivable
  #     (approved / partially received — PurchaseRequest::RECEIVABLE_STATUSES);
  #   - the request must name a responsible employee who is still eligible
  #     (purchasing permission + active custody account) — that account is the
  #     one funded (recipient_custody_account), decided by Finance & Sales
  #     through Inventory::PurchaseRequestAdvanceEffects.responsible_custody_account_id;
  #   - amount > 0 (rounded to 2 dp). NOT capped by the request total: funding
  #     is custody money for the purchase, not a supplier payment, so an excess
  #     simply stays in the responsible employee's custody;
  #   - source_kind must be a real payment kind;
  #   - employee custody: a custody TRANSFER from a source employee's account
  #     (one the actor may use — .selectable_custody_account_id; never created
  #     on the fly) that is not the responsible employee's. Its balance is NOT a
  #     limit: custody is an accounting balance and may go negative;
  #   - company cash / bank: no source account; the reference (bank transfer
  #     reference) is kept on the advance and in the custody row's notes;
  #   - the responsible employee may not record an advance on their own request
  #     (it would fund their own custody unchecked). The source employee may
  #     record a transfer from their own custody;
  #   - Finance & Sales locks the accounts and re-checks them (active, still a
  #     purchaser) before posting — a refusal rolls the advance back;
  #   - idempotency_key: a retried/double submission returns the advance
  #     already recorded under that key instead of creating a second one
  #     (unique index on business_id + idempotency_key is the backstop).
  class PurchaseRequestAdvanceRecorder
    include AuditLoggable

    Result = Struct.new(:ok, :advance, :error, keyword_init: true) { def ok? = ok }

    def initialize(purchase_request_id:, actor:, params:, idempotency_key: nil)
      @purchase_request_id = purchase_request_id
      @actor               = actor
      @params              = params.to_h.symbolize_keys
      @idempotency_key     = idempotency_key.presence
    end

    def call
      @purchase_request = PurchaseRequestPolicy::Scope.new(@actor, PurchaseRequest).resolve.find(@purchase_request_id) # warehouse reach, as PurchaseRequestApproval (Phase 2)

      existing = find_existing
      return Result.new(ok: true, advance: existing) if existing

      # The clearest refusal first (re-checked under the lock below).
      return err(:recorded_by_responsible_employee) if recorded_by_responsible_employee?

      source_kind = @params[:source_kind].to_s
      return err(:invalid_source_kind) unless PurchaseRequestAdvance::SOURCE_KINDS.include?(source_kind)

      amount = parse_amount
      return err(:amount_must_be_positive) unless amount&.positive?

      paid_on = parse_date
      return err(:invalid_payment_date) unless paid_on
      return err(:future_payment_date) if paid_on > BusinessDay.current(context: @actor.business)

      account_id = nil
      if source_kind == "employee_custody"
        account_id = Inventory::PurchaseRequestAdvanceEffects.selectable_custody_account_id(
          actor: @actor, custody_account_id: @params[:custody_account_id]
        )
        return err(:custody_account_required) unless account_id
      end

      advance = nil
      refusal = nil
      ActiveRecord::Base.transaction do
        # Serializes against other advances, reversals, receipt approvals and the
        # responsible-employee change on the same request: the checks below
        # can't be raced, and a repeated submission (same idempotency key) waits
        # here and then resolves to the first one's advance. Lock order:
        # request, then (Finance & Sales) the custody accounts in id order, then
        # the advance insert.
        @purchase_request.lock!
        return err(:not_allowed_for_status) unless @purchase_request.receivable?

        # Resolved under the lock (which the responsible-employee change also
        # takes), so the funded account is the request's current one.
        return err(:responsible_employee_required) if @purchase_request.responsible_employee_id.nil?
        return err(:recorded_by_responsible_employee) if recorded_by_responsible_employee?

        recipient_id = Inventory::PurchaseRequestAdvanceEffects.responsible_custody_account_id(
          business_id: @purchase_request.business_id, user_id: @purchase_request.responsible_employee_id
        )
        return err(:responsible_employee_ineligible) unless recipient_id
        return err(:source_is_responsible_employee) if account_id == recipient_id

        # Lock both accounts (id order) before inserting the advance, whose
        # foreign keys would otherwise take key-share locks on them first.
        Inventory::PurchaseRequestAdvanceEffects.lock_funding_accounts(
          business_id: @purchase_request.business_id, custody_account_ids: [ account_id, recipient_id ]
        )

        advance = @purchase_request.advances.create!(
          business:        @purchase_request.business,
          amount:          amount,
          source_kind:     source_kind,
          custody_account_id: account_id,
          recipient_custody_account_id: recipient_id,
          paid_on:         paid_on,
          reference:       @params[:reference].to_s.strip.presence,
          notes:           @params[:notes].to_s.strip.presence,
          idempotency_key: @idempotency_key,
          created_by:      @actor,
          status:          "confirmed",
          confirmed_by:    @actor,
          confirmed_at:    Time.current
        )

        funding = Inventory::PurchaseRequestAdvanceEffects.advance_funded(advance: advance, actor: @actor)
        unless funding.confirmed?
          refusal = err(FUNDING_REFUSALS.fetch(funding.status))
          raise ActiveRecord::Rollback
        end
        advance.update!(funding_transaction_id: funding.transaction_id)

        log_audit(actor: @actor, auditable: advance, action: "create", metadata: audit_metadata(advance, funding))
      end
      return refusal if refusal

      Result.new(ok: true, advance: advance)
    rescue ActiveRecord::RecordNotUnique
      existing = find_existing
      existing ? Result.new(ok: true, advance: existing) : err(:duplicate_submission)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, advance: e.record, error: e.record.errors.full_messages.to_sentence)
    end

    private

    FUNDING_REFUSALS = { custody_account_inactive: :custody_account_inactive,
                         employee_ineligible: :employee_ineligible }.freeze

    # The responsible employee never funds their own custody (no exemption).
    def recorded_by_responsible_employee? = @actor.id == @purchase_request.responsible_employee_id

    def find_existing
      return nil unless @idempotency_key

      PurchaseRequestAdvance.find_by(business_id: @actor.business_id, idempotency_key: @idempotency_key)
    end

    # The one audit entry of the advance (D4): the advance, its parties and the
    # custody ledger rows it posted.
    def audit_metadata(advance, funding)
      { purchase_request_id: @purchase_request.id, request_number: @purchase_request.request_number,
        supplier_id: @purchase_request.supplier_id, amount: advance.amount.to_s, source_kind: advance.source_kind,
        custody_account_id: advance.custody_account_id, employee_id: advance.custody_account&.user_id,
        responsible_employee_id: @purchase_request.responsible_employee_id,
        recipient_custody_account_id: advance.recipient_custody_account_id,
        paid_on: advance.paid_on.to_s, reference: advance.reference, status: advance.status,
        funding_transaction_id: funding.transaction_id, funding_counterparty_id: funding.counterparty_id,
        custody_entries: custody_entries(advance, funding) }
    end

    # The custody ledger rows posted (ids from Finance & Sales' answer; signed
    # amounts: the responsible credit, and for a transfer the source debit).
    def custody_entries(advance, funding)
      entries = [ { custody_transaction_id: funding.transaction_id,
                    custody_account_id: advance.recipient_custody_account_id, amount: advance.amount.to_s } ]
      return entries unless funding.counterparty_id

      entries << { custody_transaction_id: funding.counterparty_id,
                   custody_account_id: advance.custody_account_id, amount: (-advance.amount).to_s }
    end

    def parse_amount
      value = BigDecimal(@params[:amount].to_s)
      value.finite? ? value.round(2) : nil
    rescue ArgumentError, TypeError
      nil
    end

    def parse_date
      value = @params[:paid_on]
      return BusinessDay.current(context: @actor.business) if value.blank?

      value.is_a?(Date) ? value : Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end


    def err(key, **)
      Result.new(ok: false, error: I18n.t("inventory.purchase_request_advances.errors.#{key}", **))
    end
  end
end
