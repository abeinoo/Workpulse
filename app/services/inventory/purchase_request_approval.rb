module Inventory
  # Handles the Purchase Request authorization decision: draft -> pending_approval
  # (submit) -> approved | rejected. Purely an authorization decision — it
  # NEVER creates a Goods Receipt or touches inventory. "Approved" only means
  # the purchase is authorized; receiving happens later, entirely through the
  # existing GoodsReceipt workflow (see Inventory::PurchaseRequestsController#
  # new_goods_receipt and Inventory::GoodsReceiptPoster).
  #
  # Self-approval is blocked exactly like Inventory::StockIssueApproval /
  # Inventory::GoodsReceiptApproval, via the shared Approvals::SelfApproval rule.
  class PurchaseRequestApproval
    include AuditLoggable

    Result = Struct.new(:ok, :purchase_request, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(purchase_request_id:, actor:)
      @purchase_request_id = purchase_request_id
      @actor                = actor
    end

    # draft -> pending_approval
    def submit!
      return invalid_transition_error unless request.draft?

      ActiveRecord::Base.transaction do
        request.status        = "pending_approval"
        request.submitted_by  = @actor
        request.submitted_at  = Time.current
        request.save!
        log_audit(actor: @actor, auditable: request, action: "submit_for_approval",
                  changes: { status: %w[draft pending_approval] })
      end
      Result.new(ok: true, purchase_request: request)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, purchase_request: request, error: e.record.errors.full_messages.to_sentence)
    end

    # pending_approval -> approved. metadata is added to the audit entry (e.g.
    # Inventory::PurchaseRequestBulkApproval marks its approvals as one batch).
    def approve!(metadata: {})
      return self_approval_error if self_approval?
      return review_editor_error if self.class.review_editor?(request, @actor)

      transition(to: "approved", action: "approve", metadata: metadata) do
        request.approved_by = @actor
        request.approved_at = Time.current
      end
    end

    # pending_approval -> rejected
    def reject!(reason:)
      return self_approval_error if self_approval?

      reason = reason.to_s.strip
      if reason.blank?
        request.errors.add(:rejection_reason, :blank)
        return Result.new(ok: false, purchase_request: request, error: request.errors.full_messages.to_sentence)
      end

      transition(to: "rejected", action: "reject", metadata: { reason: reason }) do
        request.rejected_by     = @actor
        request.rejected_at     = Time.current
        request.rejection_reason = reason
      end
    end

    private

    def request
      @request ||= PurchaseRequest.where(business_id: @actor.business_id).find(@purchase_request_id)
    end

    # The business owner is exempt; anyone else may not approve a request
    # they submitted themselves. Also used by the index to decide which rows
    # are selectable for bulk approval.
    def self.self_approval?(request, actor)
      return false if actor.owner?

      Approvals::SelfApproval.by_requester?(approver: actor, requester: request.submitted_by_id)
    end

    def self_approval?
      self.class.self_approval?(request, @actor)
    end

    # Whoever last changed the items while the request was pending approval
    # (PurchaseRequestUpdater's "review_edit" audit, since the latest
    # submission) may not approve it — the same idea as self-approval, owner
    # exempt likewise. Derived from the audit trail, never stored.
    def self.review_editor?(request, actor)
      review_editor_ids([ request ], actor).include?(request.id)
    end

    # Batch form for list pages: the ids among `requests` whose last
    # review-time item edit is `actor`'s — one query.
    def self.review_editor_ids(requests, actor)
      return Set.new if actor.owner? || requests.empty?

      since = requests.to_h { |r| [ r.id, r.submitted_at || r.created_at ] }
      AuditLog.where(auditable_type: "PurchaseRequest", auditable_id: since.keys, action: "review_edit")
              .order(:created_at, :id).pluck(:auditable_id, :actor_id, :created_at)
              .select { |id, _, at| at >= since[id] }
              .group_by(&:first).filter_map { |id, edits| id if edits.last[1] == actor.id }.to_set
    end

    def review_editor_error
      Result.new(ok: false, purchase_request: request,
                 error: I18n.t("inventory.purchase_requests.errors.review_editor_cannot_approve"))
    end

    def self_approval_error
      Result.new(ok: false, purchase_request: request, error: Approvals::SelfApproval.error_message)
    end

    def invalid_transition_error
      Result.new(ok: false, purchase_request: request,
                error: I18n.t("inventory.purchase_requests.errors.invalid_transition"))
    end

    def transition(to:, action:, metadata: {})
      return invalid_transition_error unless request.pending_approval?

      from_status = request.status
      ActiveRecord::Base.transaction do
        request.status = to
        yield if block_given?
        request.save!
        log_audit(actor: @actor, auditable: request, action: action,
                  changes: { status: [ from_status, to ] }, metadata: metadata)
      end
      Result.new(ok: true, purchase_request: request)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, purchase_request: request, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
