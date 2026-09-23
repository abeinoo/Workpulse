module Inventory
  # Cancels an approved Purchase Request that hasn't started receiving yet.
  # Nothing was ever posted by a Purchase Request itself, so unlike voiding a
  # GoodsReceipt this never needs compensating inventory movements — it's a
  # plain status change with an audit trail.
  class PurchaseRequestCancellation
    include AuditLoggable

    Result = Struct.new(:ok, :purchase_request, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(purchase_request_id:, actor:, reason:)
      @purchase_request_id = purchase_request_id
      @actor                = actor
      @reason               = reason.to_s.strip
    end

    # approved -> cancelled (only while nothing has been received yet)
    def call
      return invalid_transition_error unless request.approved?

      if @reason.blank?
        request.errors.add(:cancellation_reason, :blank)
        return Result.new(ok: false, purchase_request: request, error: request.errors.full_messages.to_sentence)
      end

      ActiveRecord::Base.transaction do
        request.status              = "cancelled"
        request.cancelled_by        = @actor
        request.cancelled_at        = Time.current
        request.cancellation_reason = @reason
        request.save!
        log_audit(actor: @actor, auditable: request, action: "cancel",
                  changes: { status: %w[approved cancelled] }, metadata: { reason: @reason })
      end
      Result.new(ok: true, purchase_request: request)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, purchase_request: request, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def request
      @request ||= PurchaseRequest.where(business_id: @actor.business_id).find(@purchase_request_id)
    end

    def invalid_transition_error
      Result.new(ok: false, purchase_request: request,
                error: I18n.t("inventory.purchase_requests.errors.invalid_transition"))
    end
  end
end
