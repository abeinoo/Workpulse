module Inventory
  # Closes off the still-outstanding quantity on a partially_received
  # Purchase Request: the business decided not to pursue what's left.
  #
  # This NEVER touches the quantity already received — no InventoryMovement,
  # no GoodsReceipt, no stock/cost change. It only flips the request's status
  # to partially_closed, which is what blocks any further GoodsReceipt from
  # being created against it (see PurchaseRequest::RECEIVABLE_STATUSES /
  # PurchaseRequestPolicy#create_goods_receipt?) — no separate enforcement
  # needed anywhere else.
  #
  # Race-safe: locks and reloads the request, then re-checks partially_received?
  # AFTER the lock — if a concurrent GoodsReceipt confirmation finished
  # receiving the rest in the meantime (flipping the request to
  # fully_received via PurchaseRequest#sync_receiving_status!, which takes
  # the SAME row lock), this call safely fails with "already fully received"
  # instead of closing a quantity that no longer exists. The inverse race
  # (closing first, then a receipt trying to post against the closed
  # remainder) is caught symmetrically by sync_receiving_status!'s own
  # lock+reload — see that method's comment.
  class PurchaseRequestRemainingCloser
    include AuditLoggable

    Result = Struct.new(:ok, :purchase_request, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(purchase_request_id:, actor:, reason:)
      @purchase_request_id = purchase_request_id
      @actor               = actor
      @reason              = reason.to_s.strip
    end

    def call
      request.with_lock do
        return not_partially_received_error unless request.partially_received?

        remaining = request.total_requested_quantity - request.total_received_quantity
        return already_fully_received_error if remaining <= 0

        if @reason.blank?
          request.errors.add(:close_remaining_reason, :blank)
          return Result.new(ok: false, purchase_request: request, error: request.errors.full_messages.to_sentence)
        end

        previous_status = request.status
        request.status                 = "partially_closed"
        request.closed_remaining_by    = @actor
        request.closed_remaining_at    = Time.current
        request.close_remaining_reason = @reason
        request.save!

        log_audit(
          actor: @actor, auditable: request, action: "close_remaining",
          changes: { status: [ previous_status, "partially_closed" ] },
          metadata: {
            reason:              @reason,
            requested_quantity:  request.total_requested_quantity,
            received_quantity:   request.total_received_quantity,
            closed_quantity:     remaining
          }
        )
      end

      Result.new(ok: true, purchase_request: request)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, purchase_request: request, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def request
      @request ||= PurchaseRequest.where(business_id: @actor.business_id).find(@purchase_request_id)
    end

    def not_partially_received_error
      Result.new(ok: false, purchase_request: request,
                error: I18n.t("inventory.purchase_requests.errors.invalid_transition"))
    end

    def already_fully_received_error
      Result.new(ok: false, purchase_request: request,
                error: I18n.t("inventory.purchase_requests.errors.already_fully_received"))
    end
  end
end
