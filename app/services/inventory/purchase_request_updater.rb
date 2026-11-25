module Inventory
  # Edits a Purchase Request before approval, in place:
  #   - DRAFT: warehouse, notes, responsible employee and items;
  #   - PENDING APPROVAL (reviewers fixing the lines before approving): items
  #     only (add / remove / change product, supplier, quantity, unit price) —
  #     any other attribute is refused, and the request stays pending.
  # Who may edit which is the policy's (PurchaseRequestPolicy#edit_items? /
  # #update?); the state rules are enforced here, under the lock. Nothing
  # after approval is ever edited: approval is what opens receiving and
  # advances, so no financial or receiving operation can exist yet.
  # Every save is audited with the exact line changes (item_changes); a
  # pending-approval edit is audited as "review_edit", and its author may not
  # approve the request (Inventory::PurchaseRequestApproval). The saved request must
  # name an active warehouse within the actor's scope (a legacy draft without
  # one gets it here), an optional responsible employee who, when it changes to
  # someone, is eligible (purchasing permission + active custody account), and a
  # product may appear only once. This is a request-only
  # document, so editing it never touches inventory, never creates a
  # GoodsReceipt, and never regenerates the request number (only ever
  # assigned once, on first create — see PurchaseRequest#assign_request_number).
  # The request stays draft after saving; the caller must still explicitly
  # submit it for approval (Inventory::PurchaseRequestApproval#submit!).
  #
  # Race-safe: locks the row and re-checks the state AFTER acquiring the lock
  # (with_lock reloads first), so an edit that races against another user
  # submitting/approving the very same request fails safely instead of
  # silently modifying an approved record.
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
        return not_editable_error unless request.items_editable?
        return error(:only_items_during_review) if request.pending_approval? && !items_only?

        before = line_snapshot
        request.assign_attributes(@attributes)
        return error(:missing_warehouse)      if request.warehouse_id.blank?
        return error(:unauthorized_warehouse) unless warehouse_allowed?
        return error(:responsible_employee_ineligible) unless responsible_employee_allowed?
        return error(:duplicate_product)      if duplicate_products?

        request.save!
        log_audit(actor: @actor, auditable: request, action: request.pending_approval? ? "review_edit" : "update",
                  metadata: { status: request.status, item_changes: item_changes(before, line_snapshot(reload: true)) })
      end

      Result.new(ok: true, purchase_request: request)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, purchase_request: request, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def request
      @request ||= PurchaseRequestPolicy::Scope.new(@actor, PurchaseRequest).resolve.find(@purchase_request_id) # warehouse reach, as PurchaseRequestApproval (Phase 2)
    end

    def not_editable_error
      error(:invalid_transition)
    end

    def items_only?
      @attributes.to_h.keys.map(&:to_s) == [ "items_attributes" ]
    end

    LINE_FIELDS = %w[product_id supplier_id quantity unit_price].freeze

    # { item_id => { "product_id" => 12, "quantity" => "4.0", … } } — ids as
    # integers, decimals as plain strings.
    def line_snapshot(reload: false)
      items = reload ? request.items.reload : request.items
      items.to_h do |item|
        [ item.id, LINE_FIELDS.index_with { |field| item.public_send(field).then { |v| v.is_a?(BigDecimal) ? v.to_s("F") : v } } ]
      end
    end

    def item_changes(before, after)
      changed = (before.keys & after.keys).filter_map do |id|
        diff = LINE_FIELDS.select { |field| before[id][field] != after[id][field] }
        { "item_id" => id, "from" => before[id].slice(*diff), "to" => after[id].slice(*diff) } if diff.any?
      end
      { "added" => (after.keys - before.keys).map { |id| after[id].merge("item_id" => id) },
        "removed" => (before.keys - after.keys).map { |id| before[id].merge("item_id" => id) },
        "changed" => changed }
    end

    # Also added to the record, so the re-rendered edit form shows it.
    def error(key)
      message = I18n.t("inventory.purchase_requests.errors.#{key}")
      request.errors.add(:base, message)
      Result.new(ok: false, purchase_request: request, error: message)
    end

    # Same rule as the create form: an active warehouse of this business the
    # actor is assigned to. Checked when it changes (including a legacy draft
    # getting its first one), so an untouched warehouse never blocks an edit.
    def warehouse_allowed?
      return true unless request.will_save_change_to_warehouse_id?

      candidates = request.business.warehouses.operational.active.where(id: request.warehouse_id)
      scoped     = @actor.inventory_warehouse_ids
      candidates = candidates.where(id: scoped) if scoped
      candidates.exists?
    end

    # Checked when it changes to someone (a draft has no advances, so nothing
    # locks it; clearing it is allowed — it is optional until funding).
    def responsible_employee_allowed?
      return true unless request.will_save_change_to_responsible_employee_id?
      return true if request.responsible_employee_id.blank?

      Inventory::PurchaseRequestAdvanceEffects.responsible_custody_account_id(
        business_id: request.business_id, user_id: request.responsible_employee_id
      ).present?
    end

    def duplicate_products?
      ids = request.items.reject(&:marked_for_destruction?).map(&:product_id).compact
      ids.uniq.size != ids.size
    end
  end
end
