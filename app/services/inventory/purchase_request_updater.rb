module Inventory
  # Edits a DRAFT Purchase Request in place — supplier, notes, and items
  # (add/remove/change quantity/change unit price). This is a request-only
  # document, so editing it never touches inventory, never creates a
  # GoodsReceipt, and never regenerates the request number (only ever
  # assigned once, on first create — see PurchaseRequest#assign_request_number).
  # The request stays draft after saving; the caller must still explicitly
  # submit it for approval (Inventory::PurchaseRequestApproval#submit!).
  #
  # Race-safe: locks the row and re-checks draft? AFTER acquiring the lock
  # (with_lock reloads first), so an edit that races against another user
  # submitting/approving the very same request fails safely instead of
  # silently modifying a non-draft record.
  class PurchaseRequestUpdater
    include AuditLoggable

    Result = Struct.new(:ok, :purchase_request, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(purchase_request_id, actor:, attributes:)
      @purchase_request_id = purchase_request_id
      @actor               = actor
      @attributes          = attributes
    end

    def call
      request.with_lock do
        return not_draft_error unless request.draft?

        request.assign_attributes(@attributes)
        request.save!
        log_audit(actor: @actor, auditable: request, action: "update")
      end

      Result.new(ok: true, purchase_request: request)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, purchase_request: request, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def request
      @request ||= PurchaseRequest.where(business_id: @actor.business_id).find(@purchase_request_id)
    end

    def not_draft_error
      Result.new(ok: false, purchase_request: request,
                error: I18n.t("inventory.purchase_requests.errors.invalid_transition"))
    end
  end
end
