class PurchaseRequest < ApplicationRecord
  include RequiresActiveWarehouse
  include ImmutableDocument
  # Its FinancialSettlement ledger holds the CONFIRMED advance payments made to
  # the supplier against this request (see PurchaseRequestAdvance); reversals
  # are equal-and-opposite rows, so the ledger SUM is always the net advance.
  include Settleable

  # A request-only document: it never posts inventory or money itself. The
  # full lifecycle:
  #   draft -> pending_approval -> approved -> partially_received -> fully_received
  #                             -> rejected                       -> partially_closed
  #   draft -> cancelled (delete instead, see destroyable_as_draft?)
  #   approved -> cancelled (Inventory::PurchaseRequestCancellation — only
  #               while nothing has been received yet)
  #   partially_received -> partially_closed (Inventory::PurchaseRequestRemainingCloser
  #               — the business decided not to pursue what's still
  #               outstanding; the quantity already received is untouched and
  #               stays exactly as received)
  # approved/partially_received/fully_received are never set directly by a
  # human action — approved is set by Inventory::PurchaseRequestApproval#approve!,
  # and partially_received/fully_received are DERIVED from received quantities
  # and written by #sync_receiving_status!, called by
  # Inventory::GoodsReceiptConfirmationService every time a linked
  # GoodsReceipt is confirmed. Never confuse "approved" (authorized to buy)
  # with the goods actually having arrived — that's what the receiving states
  # track. partially_closed is terminal for receiving purposes: it is
  # deliberately excluded from RECEIVABLE_STATUSES below, and
  # #sync_receiving_status! never overwrites it (see its own lock/reload).
  enum :status, { draft: "draft", pending_approval: "pending_approval", approved: "approved",
                  partially_received: "partially_received", partially_closed: "partially_closed",
                  fully_received: "fully_received", rejected: "rejected", cancelled: "cancelled" }

  # Identifies what generated this request, e.g. "low_stock_alert". nil for a
  # (future) manually-created request.
  SOURCE_LOW_STOCK_ALERT = "low_stock_alert".freeze

  # A Purchase Request may be received into a Goods Receipt once it's been
  # authorized and still has something outstanding. partially_closed is
  # intentionally absent — that status exists specifically to shut this off
  # for the remaining, unreceived quantity.
  RECEIVABLE_STATUSES = %w[approved partially_received].freeze

  # Requests that currently require a human to do something next — used by
  # the "تحتاج إجراء" quick filter. approved always means zero received yet
  # (see #sync_receiving_status!), so it doesn't need a separate quantity
  # check here.
  NEEDS_ACTION_STATUSES = %w[draft pending_approval approved partially_received].freeze

  belongs_to :business
  # Optional at every stage: a request says WHAT to buy, not necessarily WHO
  # from — the goods may end up bought from several suppliers or an unknown
  # vendor. When set, every Goods Receipt against it must use this supplier;
  # when nil, each receipt records its own actual supplier (see
  # GoodsReceipt#purchase_request_supplier_matches).
  # LEGACY: requests created before the warehouse/supplier refactor named one
  # request-level supplier. New requests leave it nil and carry the supplier on
  # each line instead (PurchaseRequestItem#supplier), so one request may buy
  # from several suppliers. Kept read-only for those historical requests.
  belongs_to :supplier, optional: true
  # The one destination warehouse every line of the request goes to. Required
  # for every request created or edited from now on (enforced by
  # Inventory::PurchaseRequestCreator / PurchaseRequestUpdater, which also
  # check the actor's warehouse scope); nil only on a legacy request whose
  # lines named no single warehouse — see #receiving_warehouse_id.
  belongs_to :warehouse, optional: true
  # "الموظف المسؤول عن الشراء": accountable for purchasing and receiving, and
  # the custody every advance on this request funds (PurchaseRequestAdvance).
  # Optional when the request is created; assigned later through
  # Inventory::PurchaseRequestResponsibleAssigner (never automatically, never
  # back-filled). Required before any advance is recorded (and with it funded —
  # Inventory::PurchaseRequestAdvanceRecorder) and before a receipt from this
  # request is paid from custody (#custody_payment_refusal). Whoever is assigned must hold
  # create_purchase_requests and an active custody account and be active,
  # checked by the services through Inventory::PurchaseRequestAdvanceEffects.
  belongs_to :responsible_employee, class_name: "User", optional: true
  belongs_to :created_by,           class_name: "User", optional: true
  belongs_to :submitted_by,         class_name: "User", optional: true
  belongs_to :approved_by,          class_name: "User", optional: true
  belongs_to :rejected_by,          class_name: "User", optional: true
  belongs_to :cancelled_by,         class_name: "User", optional: true
  belongs_to :closed_remaining_by,  class_name: "User", optional: true

  has_many :items, class_name: "PurchaseRequestItem", dependent: :destroy
  has_many :goods_receipts, dependent: :restrict_with_error
  has_many :advances, class_name: "PurchaseRequestAdvance", dependent: :restrict_with_error

  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:product_id].blank? }

  validates :request_number, uniqueness: { scope: :business_id, case_sensitive: false }, allow_nil: true
  validate :supplier_in_same_business
  validate :warehouse_in_same_business, if: :will_save_change_to_warehouse_id?
  # Inactive warehouse: no new request for it, no submission or approval —
  # neither for the destination nor for any line's source warehouse.
  requires_active_warehouse :warehouse, transitions: { status: %w[pending_approval approved] }
  validate :line_source_warehouses_active, if: -> { will_save_change_to_status?(to: "pending_approval") || will_save_change_to_status?(to: "approved") }
  validate :responsible_employee_in_same_business, if: :will_save_change_to_responsible_employee_id?
  validate :has_at_least_one_item

  before_create :assign_request_number

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(created_at: :desc, id: :desc) }
  # NO_SUPPLIER_FILTER selects the requests with no supplier set — neither the
  # legacy request-level one nor any line's.
  NO_SUPPLIER_FILTER = "none".freeze
  ITEM_SUPPLIER_SQL = "EXISTS (SELECT 1 FROM purchase_request_items pri_s " \
                      "WHERE pri_s.purchase_request_id = purchase_requests.id AND %s)".freeze
  scope :for_supplier, ->(supplier_id) {
    if supplier_id.to_s == NO_SUPPLIER_FILTER
      where(supplier_id: nil).where.not(format(ITEM_SUPPLIER_SQL, "pri_s.supplier_id IS NOT NULL"))
    elsif supplier_id.present?
      where(supplier_id: supplier_id)
        .or(where(format(ITEM_SUPPLIER_SQL, "pri_s.supplier_id = :id"), id: supplier_id.to_i))
    end
  }
  scope :for_creator,  ->(user_id)     { where(created_by_id: user_id) if user_id.present? }
  scope :on_or_after,  ->(date)        { where(created_at: date.beginning_of_day..) if date.present? }
  scope :on_or_before, ->(date)        { where(created_at: ..date.end_of_day) if date.present? }
  scope :for_status,   ->(status)      { where(status: status) if status.present? && statuses.key?(status) }

  # Number, supplier (the legacy request-level one or any line's), or a
  # product's name/SKU on any line.
  scope :search, ->(term) {
    return all if term.blank?

    t = "%#{term.to_s.strip.downcase}%"
    left_joins(:supplier).where(
      "LOWER(purchase_requests.request_number) LIKE :t OR LOWER(suppliers.name) LIKE :t OR " \
      "EXISTS (SELECT 1 FROM purchase_request_items pri JOIN products p ON p.id = pri.product_id " \
      "LEFT JOIN suppliers s ON s.id = pri.supplier_id " \
      "WHERE pri.purchase_request_id = purchase_requests.id " \
      "AND (LOWER(p.sku) LIKE :t OR LOWER(p.name) LIKE :t OR LOWER(s.name) LIKE :t))",
      t: t
    )
  }

  # "الكل" / "لم يبدأ الاستلام" / "استلام جزئي" / "مستلم بالكامل" filter —
  # mirrors the receiving *state*, not the raw status column, so it stays
  # correct even though "approved" also means "not started."
  scope :for_receiving_status, ->(status) {
    case status
    when "not_started" then where(status: %w[approved])
    when "partial"     then where(status: "partially_received")
    when "closed"      then where(status: "partially_closed")
    when "full"        then where(status: "fully_received")
    end
  }

  scope :needs_action, -> { where(status: NEEDS_ACTION_STATUSES) }

  # A draft with nothing posted anywhere yet is safe to delete outright —
  # matches StockIssue's rationale exactly (see ImmutableDocument).
  def destroyable_as_draft?
    draft?
  end

  def total_amount
    items.sum(&:total_cost)
  end

  def total_requested_quantity
    items.sum(&:quantity)
  end

  # Sums the loaded receipt lines when the page preloaded them; otherwise one
  # grouped query for every line (PurchaseRequestItem.received_quantities).
  def total_received_quantity
    if items.loaded? && items.all? { |item| item.goods_receipt_items.loaded? }
      items.sum(&:received_quantity)
    else
      PurchaseRequestItem.received_quantities(items.to_a).values.sum
    end
  end

  def receivable?
    RECEIVABLE_STATUSES.include?(status)
  end

  # Items may change only before approval: approval is what opens receiving and
  # advances, so nothing financial or received can exist yet. Who may edit in
  # which state is PurchaseRequestPolicy's; Inventory::PurchaseRequestUpdater
  # enforces the state under the row lock.
  ITEMS_EDITABLE_STATUSES = %w[draft pending_approval].freeze

  def items_editable?
    ITEMS_EDITABLE_STATUSES.include?(status)
  end

  # ── Warehouse / suppliers ──────────────────────────────────────────────────

  # A legacy request names one supplier for the whole request; every Goods
  # Receipt against it is locked to that supplier.
  def legacy_supplier?
    supplier_id.present?
  end

  # Distinct suppliers on the request's lines (in line order), or the legacy
  # request-level supplier. Uses loaded associations when preloaded.
  def suppliers_on_items
    return [ supplier ].compact if legacy_supplier?

    items.reject(&:marked_for_destruction?).filter_map(&:supplier).uniq
  end

  # Who may pay a Goods Receipt from this request out of custody: only its
  # responsible employee — the one its advances funded — and nobody while it
  # has none (assign one first, never automatically). nil when `user_id` may;
  # otherwise the refusal (an error key under goods_receipt's base errors and
  # the settlement errors). The one rule behind GoodsReceipt's validation,
  # approval (Inventory::GoodsReceiptApproval) and later custody payments
  # (Inventory::GoodsReceiptSettlementRecorder).
  def custody_payment_refusal(user_id)
    return :custody_payment_requires_responsible if responsible_employee_id.nil?
    return :custody_payment_responsible_only if user_id.nil? || user_id != responsible_employee_id

    nil
  end

  # ── Receiving: one Goods Receipt per supplier group ─────────────────────────
  # A receipt from this request takes the OUTSTANDING lines (remaining
  # quantity > 0 — PurchaseRequestItem#remaining_quantity, confirmed non-voided
  # receipts only) of exactly one supplier group: one supplier's lines, or the
  # lines without a supplier, which are received in their own receipt. A
  # legacy one-supplier request is a single group. GoodsReceipt /
  # GoodsReceiptItem enforce the same groups server-side.

  # The groups that still have something to receive, in line order with the
  # lines without a supplier last: Supplier records, nil for "no supplier".
  # Empty for a legacy request (its one supplier is fixed). Uses loaded
  # items / suppliers when preloaded.
  def receiving_supplier_groups
    return [] if legacy_supplier?

    groups = outstanding_items.map(&:supplier).uniq
    groups.compact + (groups.include?(nil) ? [ nil ] : [])
  end

  # The outstanding lines a receipt for `supplier_id` (nil = the lines without
  # a supplier) may receive. A legacy request: all of its outstanding lines.
  def outstanding_items_for_supplier(supplier_id)
    return outstanding_items if legacy_supplier?

    outstanding_items.select { |item| item.supplier_id == supplier_id }
  end

  # The warehouse a Goods Receipt from this request is preselected with: the
  # request's own, or — for a legacy request — the one warehouse all of its
  # lines named. nil when there is no single answer (never a guess).
  def receiving_warehouse_id
    return warehouse_id if warehouse_id.present?

    ids = items.map(&:source_warehouse_id)
    ids.first if ids.any? && ids.all?(&:present?) && ids.uniq.size == 1
  end

  def outstanding_items
    items.reject(&:marked_for_destruction?).select { |item| item.remaining_quantity.positive? }
  end

  # ── Advance payments ───────────────────────────────────────────────────────
  # Every figure below is derived from the FinancialSettlement ledgers (this
  # request's, and its receipts'), never stored.

  # Settleable's required hook: advances may never exceed the request's value.
  alias_method :settlement_total, :total_amount

  # Net confirmed advances (reversed ones net to zero).
  def advances_total = total_settled_amount

  # "المتبقي": request total minus confirmed advances.
  def amount_remaining_after_advances = remaining_settlement_amount

  # Part of the confirmed advances already consumed by approved receipts.
  def applied_advances_total
    FinancialSettlement.advance_applications
                       .where(funding_source_type: "PurchaseRequestAdvance", funding_source_id: advances.select(:id))
                       .sum(:amount)
  end

  # Advance money still held by the supplier, to be deducted from the next
  # approved receipt(s).
  def unapplied_advances_total
    [ advances_total - applied_advances_total, 0 ].max
  end

  # Confirmed (not reversed) funding of the responsible employee's custody —
  # money the employee holds for this request, not a supplier payment. Not
  # capped by the request total (an excess simply stays in that custody), and
  # never part of advances_total / amount_remaining_after_advances or the
  # receipt deduction, which count supplier payments only.
  def confirmed_funding_total
    advances.confirmed.where.not(recipient_custody_account_id: nil).sum(:amount)
  end

  # The responsible employee may change only while no funding advance is
  # pending or confirmed (unreversed): those name the current employee's
  # custody. Cancel or reverse them first.
  def responsible_employee_locked?
    advances.where(status: %w[pending confirmed]).where.not(recipient_custody_account_id: nil).exists?
  end

  # Amount closed off without being received — only meaningful once
  # partially_closed; derived the same way #remaining_quantity always is, not
  # frozen at the moment of closing, so it can never drift.
  def closed_remaining_quantity
    return 0 unless partially_closed?

    [ total_requested_quantity - total_received_quantity, 0 ].max
  end

  # Recomputes approved/partially_received/fully_received from actual
  # received quantities — called by Inventory::GoodsReceiptConfirmationService
  # right after a linked GoodsReceipt is confirmed.
  #
  # Locks and reloads itself FIRST, then decides — this is what makes it
  # race-safe against Inventory::PurchaseRequestRemainingCloser running
  # concurrently on the same request. Without the lock+reload, this method
  # could act on a stale in-memory status (loaded before a concurrent close
  # committed) and blindly overwrite a freshly-set partially_closed back to
  # partially_received/fully_received via update_column. With it: whichever
  # of the two transactions (this one, or the closer's) acquires the row
  # lock first wins, and the second sees the first's already-committed
  # result once it proceeds — never a lost update.
  #
  # A no-op once the request has left the receivable states (e.g. cancelled,
  # or already partially_closed) so a stray call can never resurrect or
  # clobber a terminal status.
  def sync_receiving_status!
    with_lock do
      return unless receivable?

      requested = total_requested_quantity
      received  = total_received_quantity

      new_status =
        if received <= 0
          "approved"
        elsif received >= requested
          "fully_received"
        else
          "partially_received"
        end

      update_column(:status, new_status) if new_status != status
    end
  end

  private

  def assign_request_number
    self.request_number ||= Inventory::NumberSequencer.new(business, :purchase_request).next_number
  end

  def has_at_least_one_item
    errors.add(:base, :no_items) if items.reject(&:marked_for_destruction?).empty?
  end

  # Also rejects an id that doesn't resolve to a supplier at all — the
  # association is optional, so belongs_to no longer reports "must exist".
  def supplier_in_same_business
    return errors.add(:supplier, :invalid) if supplier_id.present? && supplier.nil?
    return if supplier.nil? || business_id.nil?

    errors.add(:supplier, :invalid) if supplier.business_id != business_id
  end

  def responsible_employee_in_same_business
    return errors.add(:responsible_employee, :invalid) if responsible_employee_id.present? && responsible_employee.nil?
    return if responsible_employee.nil? || business_id.nil?

    errors.add(:responsible_employee, :invalid) if responsible_employee.business_id != business_id
  end

  def warehouse_in_same_business
    return errors.add(:warehouse, :invalid) if warehouse_id.present? && warehouse.nil?
    return if warehouse.nil? || business_id.nil?

    errors.add(:warehouse, :invalid) if warehouse.business_id != business_id
  end

  # Submitting or approving a request whose line sources from an inactive
  # warehouse (RequiresActiveWarehouse covers the destination).
  def line_source_warehouses_active
    items.reject(&:marked_for_destruction?).filter_map(&:source_warehouse).uniq.each do |source|
      errors.add(:base, :warehouse_inactive, warehouse: source.name) unless source.active?
    end
  end
end
