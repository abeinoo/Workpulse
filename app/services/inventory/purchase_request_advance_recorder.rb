module Inventory
  # Records a PENDING advance payment against a Purchase Request. Nothing
  # financial happens here — no settlement, no custody movement. Money moves
  # only when the advance is confirmed (Inventory::PurchaseRequestAdvanceWorkflow#confirm!).
  #
  # Server-side rules (the form is never trusted):
  #   - the request must belong to the actor's business and be receivable
  #     (approved / partially received — PurchaseRequest::RECEIVABLE_STATUSES);
  #   - amount > 0 and within the request's remaining unpaid amount, counting
  #     confirmed advances, direct receipt payments and other PENDING advances;
  #   - source_kind must be a real payment kind;
  #   - employee custody: the employee must already HAVE an active custody
  #     account, and it must be one the actor may pay from — decided by Finance &
  #     Sales through Inventory::PurchaseRequestAdvanceEffects
  #     .selectable_custody_account_id (S2) — never created on the fly. Its balance
  #     is NOT a limit: custody is an accounting balance and may go negative
  #     (the employee paid on the business's behalf beyond their float);
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
      @purchase_request = PurchaseRequest.where(business_id: @actor.business_id).find(@purchase_request_id)

      existing = find_existing
      return Result.new(ok: true, advance: existing) if existing

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
      ActiveRecord::Base.transaction do
        # Serializes against other advances, confirmations and receipt approvals
        # on the same request, so the capacity check below can't be raced.
        @purchase_request.lock!
        return err(:not_allowed_for_status) unless @purchase_request.receivable?

        capacity = @purchase_request.advance_capacity(pending_total: @purchase_request.advances.pending.sum(:amount))
        return err(:exceeds_remaining, remaining: format_amount(capacity)) if amount > capacity

        advance = @purchase_request.advances.create!(
          business:        @purchase_request.business,
          amount:          amount,
          source_kind:     source_kind,
          custody_account_id: account_id,
          paid_on:         paid_on,
          reference:       @params[:reference].to_s.strip.presence,
          notes:           @params[:notes].to_s.strip.presence,
          idempotency_key: @idempotency_key,
          created_by:      @actor
        )

        log_audit(actor: @actor, auditable: advance, action: "create", metadata: audit_metadata(advance))
      end

      Result.new(ok: true, advance: advance)
    rescue ActiveRecord::RecordNotUnique
      existing = find_existing
      existing ? Result.new(ok: true, advance: existing) : err(:duplicate_submission)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, advance: e.record, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def find_existing
      return nil unless @idempotency_key

      PurchaseRequestAdvance.find_by(business_id: @actor.business_id, idempotency_key: @idempotency_key)
    end

    def audit_metadata(advance)
      { purchase_request_id: @purchase_request.id, request_number: @purchase_request.request_number,
        supplier_id: @purchase_request.supplier_id, amount: advance.amount.to_s, source_kind: advance.source_kind,
        custody_account_id: advance.custody_account_id, employee_id: advance.custody_account&.user_id,
        paid_on: advance.paid_on.to_s, reference: advance.reference, status: advance.status }
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

    def format_amount(value)
      ActiveSupport::NumberHelper.number_to_rounded(value, precision: 2, delimiter: ",")
    end

    def err(key, **)
      Result.new(ok: false, error: I18n.t("inventory.purchase_request_advances.errors.#{key}", **))
    end
  end
end
