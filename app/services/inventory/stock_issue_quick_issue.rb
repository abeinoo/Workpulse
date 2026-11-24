module Inventory
  # Quick Issue — its own workflow, posted immediately: one warehouse, one
  # fixed reason and EXACTLY ONE product, issued in a single step from a
  # warehouse the actor is AUTHORIZED to use (Inventory::IssueWarehouseReach —
  # the same rule as the Standard Stock Issue): the only one they reach is
  # used automatically; with several, the caller passes the chosen one, which
  # is re-checked here (never trusted, never replaced by another).
  #
  # It is NOT a second stock-issue implementation. It builds an ordinary
  # StockIssue (workflow "quick_issue", one line) and drives it through the
  # standard workflow services, in order, inside ONE transaction:
  #
  #   StockIssueDraftService        draft            ("create")
  #   StockIssueSubmission          -> pending_approval ("submit_for_approval")
  #   StockIssueApproval            -> approved, reserved ("approve", quick_issue / automatic)
  #   StockIssueConfirmationService -> issued via StockIssuePoster ("confirm")
  #
  # so movements, average costing, reservation protection, the product lock
  # and the availability re-check under lock are exactly those of a regular
  # issue. All four audit entries are mandatory: if any step — or any audit
  # write — fails, the whole transaction rolls back and nothing is left behind
  # (no draft, no reservation, no movement).
  #
  # Authorization (checked here, whoever the caller):
  #   - quick_issue_stock (not create/approve/confirm), and the business's
  #     Quick Issue setting must be enabled — the owner may always use it;
  #   - the warehouse: active, of the actor's business, and one the actor may
  #     use (Inventory::IssueWarehouseReach) — independent of the permission.
  #     It is re-verified under lock at approval and confirmation
  #     (StockIssueApproval / StockIssueConfirmationService).
  # The standard step services are called with this class's private CONTEXT,
  # which replaces only their standard operation-permission check (see
  # Inventory::StockIssueAuthorization.step_permitted?). CONTEXT is accepted by
  # identity only, so it cannot be forged; warehouse reach,
  # business isolation, locks, availability and audit are never bypassed.
  # Standard self-approval prohibition does not apply: the automatic approval
  # of the actor's own submission is the Quick Issue workflow, recorded as such.
  #
  # One product: product_id and quantity are single values. A collection in
  # either (several products / lines) is refused — there is no multi-line
  # contract — and StockIssue itself refuses a quick_issue created with any
  # other number of items. Quantities are inventory units, BigDecimal (at most
  # QUANTITY_SCALE decimals).
  #
  # Result#field_errors: { product:, quantity:, warehouse:, notes: } — the message to
  # show beside that field (Result#error carries the same message).
  class StockIssueQuickIssue
    Result = Struct.new(:ok, :issue, :error, :field_errors, keyword_init: true) do
      def ok? = ok
    end

    CONTEXT = Object.new.tap { |context| def context.inspect = "#<Inventory::StockIssueQuickIssue context>" }.freeze
    private_constant :CONTEXT

    QUANTITY_SCALE = 3

    # Identity check performed by CONTEXT itself (a forged object cannot answer
    # for it by overriding #equal? or #==).
    def self.trusted_context?(object) = CONTEXT.equal?(object)

    # Quick Issue availability: the owner always; anyone else needs
    # quick_issue_stock (transitionally also manage_inventory) and the
    # business's Quick Issue setting enabled.
    def self.permitted?(user)
      return false if user.nil?
      return true if user.owner?

      user.business&.quick_issue_enabled? == true && StockIssueAuthorization.permits?(user, :quick_issue)
    end

    # The quantity available to a Quick Issue of `product_ids` from `warehouse_ids`
    # — on hand minus what approved issues already reserve, never negative —
    # as { [warehouse_id, product_id] => BigDecimal }. The figure the popup
    # shows and the read-only pre-check uses (two aggregate queries); the
    # authoritative check is repeated under the product lock while posting.
    def self.available_by(warehouse_ids:, product_ids:)
      warehouse_ids = Array(warehouse_ids)
      product_ids   = Array(product_ids)
      return {} if warehouse_ids.empty? || product_ids.empty?

      on_hand  = StockAvailability.on_hand_by(warehouse_ids: warehouse_ids, product_ids: product_ids)
      reserved = StockAvailability.reserved_by(warehouse_ids: warehouse_ids, product_ids: product_ids)
      warehouse_ids.product(product_ids).to_h do |key|
        [ key, [ on_hand[key].to_d - reserved[key].to_d, BigDecimal("0") ].max ]
      end
    end

    # warehouse_id: optional when the actor reaches exactly one active
    # warehouse (used automatically); required — and re-checked — otherwise.
    # notes: the only free text. Optional, except for the "other" reason,
    # whose explanation it is: then required, and also recorded as the issue's
    # reason note (stock_issues.issue_reason_note — required by the database
    # for "other"; the audit metadata carries it as before).
    def initialize(actor:, product_id:, quantity:, reason:, warehouse_id: nil, notes: nil)
      @actor        = actor
      @warehouse_id = warehouse_id
      @product_id   = product_id
      @quantity     = quantity
      @reason       = reason.to_s.strip.presence
      @notes        = notes.to_s.strip.presence
      @reason_note  = (@notes if @reason == "other")
      @field_errors = {}
    end

    def call
      return failure(I18n.t("inventory.quick_issue.errors.not_permitted")) unless self.class.permitted?(@actor)
      return field_failure(:product, I18n.t("inventory.quick_issue.errors.single_product_only")) if several_products?

      warehouse = authorized_warehouse
      return field_failure(:warehouse, @warehouse_error) unless warehouse

      reason_error = validate_reason
      return failure(reason_error) if reason_error
      return field_failure(:notes, I18n.t("inventory.quick_issue.errors.notes_required_for_other")) if @reason == "other" && @notes.nil?

      product = find_product
      return field_failure(:product, @product_error) unless product

      quantity = parse_quantity(@quantity)
      return field_failure(:quantity, I18n.t("inventory.quick_issue.errors.quantity_invalid")) unless quantity

      shortage = precheck_availability(product, quantity, warehouse)
      return field_failure(:quantity, shortage) if shortage

      issue = build_issue(warehouse, product, quantity)
      error = nil
      ActiveRecord::Base.transaction do
        error = run_workflow(issue)
        raise ActiveRecord::Rollback if error
      end
      return failure(error) if error

      Result.new(ok: true, issue: issue, field_errors: {})
    rescue AuditLoggable::AuditWriteFailed
      failure(I18n.t("inventory.quick_issue.errors.audit_failed"))
    end

    private

    # Several products or quantities in one call (an Array / Hash / params
    # collection) — refused whole, never partly accepted.
    def several_products? = @product_id.respond_to?(:each) || @quantity.respond_to?(:each)

    # Each step is the regular workflow service, called with CONTEXT; returns
    # the first error message, or nil when the issue ended up "issued".
    def run_workflow(issue)
      draft = StockIssueDraftService.new(issue, actor: @actor, context: CONTEXT,
                                                audit_metadata: { workflow: "quick_issue", issue_reason: @reason,
                                                                  issue_reason_note: @reason_note }.compact).call
      return issue.errors.full_messages.to_sentence.presence || I18n.t("inventory.quick_issue.errors.failed") unless draft.ok?

      steps = [
        -> { StockIssueSubmission.new(stock_issue_id: issue.id, actor: @actor, context: CONTEXT).call },
        -> { StockIssueApproval.new(stock_issue_id: issue.id, actor: @actor, context: CONTEXT).approve! },
        -> { StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: @actor, context: CONTEXT).call }
      ]
      steps.each do |step|
        result = step.call
        return result.error.presence || I18n.t("inventory.quick_issue.errors.failed") unless result.ok?
      end
      nil
    end

    # The warehouse to issue from (nil, with @warehouse_error set, when there
    # is none the actor may use): the submitted one if it is issuable; the
    # only reachable one when none was submitted. A submitted warehouse the
    # actor may not use is refused, never swapped for another.
    def authorized_warehouse
      reach = IssueWarehouseReach.for(@actor)
      if reach.none?
        @warehouse_error = reach.message
        return nil
      end

      id = @warehouse_id.respond_to?(:each) ? nil : @warehouse_id.to_s.strip.presence
      id ||= reach.default_warehouse_id if @warehouse_id.blank?
      if id.nil?
        @warehouse_error = I18n.t("inventory.issue_warehouse.errors.required")
        return nil
      end
      unless reach.issuable?(id)
        @warehouse_error = reach.message
        return nil
      end

      Warehouse.find_by(id: id.to_i, business_id: @actor.business_id)
    end

    def build_issue(warehouse, product, quantity)
      issue = @actor.business.stock_issues.build(
        warehouse: warehouse, issued_on: BusinessDay.current(context: @actor.business),
        notes: @notes, created_by: @actor,
        workflow: "quick_issue", issue_reason: @reason, issue_reason_note: @reason_note
      )
      issue.items.build(product: product, quantity: quantity)
      issue
    end

    def validate_reason
      return I18n.t("inventory.quick_issue.errors.reason_required") if @reason.nil?
      return I18n.t("inventory.quick_issue.errors.reason_invalid") unless StockIssue::QUICK_ISSUE_REASONS.include?(@reason)

      nil
    end

    # A transactable product of the actor's business, or nil (@product_error set).
    def find_product
      id = @product_id.to_s.strip
      if id.empty?
        @product_error = I18n.t("inventory.quick_issue.errors.product_required")
        return nil
      end

      product = Product.where(business_id: @actor.business_id).transactable.find_by(id: id) if id.match?(/\A\d+\z/)
      @product_error = I18n.t("inventory.quick_issue.errors.product_unavailable") unless product
      product
    end

    def parse_quantity(raw)
      value = BigDecimal(raw.to_s.strip)
      return nil unless value.positive? && value.round(QUANTITY_SCALE) == value

      value
    rescue ArgumentError, TypeError
      nil
    end

    # Read-only pre-check with a clear message (nil when enough is available).
    # The authoritative check is repeated under the product lock by the
    # approval and the poster.
    def precheck_availability(product, quantity, warehouse)
      available = self.class.available_by(warehouse_ids: [ warehouse.id ], product_ids: [ product.id ])
                      .fetch([ warehouse.id, product.id ], BigDecimal("0"))
      return nil if quantity <= available

      I18n.t("inventory.quick_issue.errors.insufficient",
             product: product.name, available: StockAvailability.format_quantity(available),
             requested: StockAvailability.format_quantity(quantity), warehouse: warehouse.name)
    end

    def field_failure(field, message)
      @field_errors[field] = message
      failure(message)
    end

    def failure(error)
      Result.new(ok: false, issue: nil, error: error, field_errors: @field_errors)
    end
  end
end
