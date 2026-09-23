class PurchaseRequest < ApplicationRecord
  include ImmutableDocument

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
  belongs_to :supplier
  belongs_to :created_by,           class_name: "User", optional: true
  belongs_to :submitted_by,         class_name: "User", optional: true
  belongs_to :approved_by,          class_name: "User", optional: true
  belongs_to :rejected_by,          class_name: "User", optional: true
  belongs_to :cancelled_by,         class_name: "User", optional: true
  belongs_to :closed_remaining_by,  class_name: "User", optional: true

  has_many :items, class_name: "PurchaseRequestItem", dependent: :destroy
  has_many :goods_receipts, dependent: :restrict_with_error

  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:product_id].blank? }

  validates :request_number, uniqueness: { scope: :business_id, case_sensitive: false }, allow_nil: true
  validate :supplier_in_same_business
  validate :has_at_least_one_item

  before_create :assign_request_number

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(created_at: :desc, id: :desc) }
  scope :for_supplier, ->(supplier_id) { where(supplier_id: supplier_id) if supplier_id.present? }
  scope :for_creator,  ->(user_id)     { where(created_by_id: user_id) if user_id.present? }
  scope :on_or_after,  ->(date)        { where(created_at: date.beginning_of_day..) if date.present? }
  scope :on_or_before, ->(date)        { where(created_at: ..date.end_of_day) if date.present? }
  scope :for_status,   ->(status)      { where(status: status) if status.present? && statuses.key?(status) }

  # Number, supplier, or a product's name/SKU on any line.
  scope :search, ->(term) {
    return all if term.blank?

    t = "%#{term.to_s.strip.downcase}%"
    left_joins(:supplier).where(
      "LOWER(purchase_requests.request_number) LIKE :t OR LOWER(suppliers.name) LIKE :t OR " \
      "EXISTS (SELECT 1 FROM purchase_request_items pri JOIN products p ON p.id = pri.product_id " \
      "WHERE pri.purchase_request_id = purchase_requests.id AND (LOWER(p.sku) LIKE :t OR LOWER(p.name) LIKE :t))",
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

  def total_received_quantity
    items.sum(&:received_quantity)
  end

  def receivable?
    RECEIVABLE_STATUSES.include?(status)
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

  def supplier_in_same_business
    return if supplier.nil? || business_id.nil?

    errors.add(:supplier, :invalid) if supplier.business_id != business_id
  end
end
