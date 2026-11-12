# A physical-inventory count for one warehouse, run as a session:
#
#   draft        — created with every product preloaded as a row, system quantity
#                  snapshotted from live stock (display only)
#   in_progress  — counting underway; counted quantities editable. Each physical
#                  entry records its own count time and the ledger quantity at
#                  that moment (StockCountItem#system_quantity).
#   completed    — counter has submitted; counts locked, AWAITING APPROVAL.
#                  Inventory is not changed by completing.
#   approved     — approver has approved → ONE stock-count Inventory Adjustment
#                  is posted from the non-zero differences (counted − ledger
#                  quantity at count time), so movements after the count are
#                  preserved.
#   cancelled    — terminal; only for a reopened count that once posted stock
#                  (such a count is never hard-deleted).
#
# Reopening an approved count voids its active adjustment (compensating
# movements) and returns it to in_progress; a count therefore owns many
# adjustments over its life, at most one active (DB partial unique index).
#
# Every transition goes through a service in Inventory::StockCount* — the
# model only holds derived state and guard rails.
class StockCount < ApplicationRecord
  belongs_to :business
  belongs_to :warehouse
  belongs_to :created_by,       class_name: "User", optional: true
  belongs_to :completed_by,     class_name: "User", optional: true
  belongs_to :approved_by,      class_name: "User", optional: true
  belongs_to :cancelled_by,     class_name: "User", optional: true
  # Pre-repair link (stock_counts.stock_adjustment_id). Historical data only —
  # no longer written; the canonical link is stock_adjustments.stock_count_id.
  belongs_to :legacy_stock_adjustment, class_name: "StockAdjustment",
             foreign_key: :stock_adjustment_id, optional: true

  has_many :items, class_name: "StockCountItem", dependent: :destroy
  has_many :stock_adjustments, inverse_of: :stock_count, dependent: :restrict_with_exception

  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:product_id].blank? }

  enum :status, { draft: "draft", in_progress: "in_progress", completed: "completed",
                  approved: "approved", cancelled: "cancelled" }

  # count_number is auto-assigned in before_create (which runs inside the save
  # transaction, so the advisory lock is held to commit); the DB NOT NULL + unique
  # index are the hard guards, so only uniqueness-when-present is validated here.
  validates :count_number, uniqueness: { scope: :business_id, case_sensitive: false }, allow_nil: true
  validates :counted_on, presence: true
  validates :cancel_reason, presence: true, if: :cancelled?
  validate  :has_at_least_one_item
  validate  :products_are_unique
  validate  :warehouse_in_same_business, if: :will_save_change_to_warehouse_id?

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(counted_on: :desc, id: :desc) }

  before_create  :assign_count_number
  before_update  :reject_changes_when_frozen
  before_destroy :reject_destroy_unless_deletable, prepend: true

  # Counts may only be edited while the session is still being worked on.
  def editable_counts?
    draft? || in_progress?
  end

  # "Counted by" / "Approved by" — the audit trail of who did what.
  def counted_by
    created_by
  end

  # The adjustment currently in effect (not voided), if any.
  def active_stock_adjustment
    if stock_adjustments.loaded?
      stock_adjustments.detect(&:active?)
    else
      stock_adjustments.active.first
    end
  end

  # True once this count has posted stock at least once — even if every
  # adjustment was later voided by a reopen. Such a count is never
  # hard-deleted (the voided adjustments reference it); it can be cancelled.
  def ever_posted?
    return true if stock_adjustment_id.present?

    stock_adjustments.loaded? ? stock_adjustments.any? : stock_adjustments.exists?
  end

  # Hard deletion: only a count still being worked on that never posted stock.
  def deletable?
    (draft? || in_progress?) && !ever_posted?
  end

  # Cancellation: a reopened count that once posted stock.
  def cancellable?
    in_progress? && ever_posted?
  end

  # ── Counting progress ────────────────────────────────────────────────────
  def counted_items      = items.select(&:counted?)
  def total_products     = items.size
  def counted_products   = counted_items.size
  def remaining_products = total_products - counted_products
  alias_method :uncounted_count, :remaining_products

  # Rows holding a pre-upgrade quantity with no trustworthy count time.
  def legacy_items = items.select(&:legacy_unverified?)
  def legacy_items? = legacy_items.any?

  def completion_percentage
    return 0 if total_products.zero?
    (counted_products * 100.0 / total_products).round
  end

  def fully_counted?
    remaining_products.zero? && total_products.positive?
  end

  # ── Variance / report figures (counted rows only) ────────────────────────
  def matched_count  = counted_items.count { |i| i.difference.to_d.zero? }
  def shortage_count = counted_items.count { |i| i.difference.to_d.negative? }
  def overage_count  = counted_items.count { |i| i.difference.to_d.positive? }

  def variance_total
    counted_items.sum { |item| item.difference.to_d }
  end

  # Signed monetary impact of the count (positive = stock gained), valued at each
  # product's current average cost — the value the approval will post to the ledger.
  def adjustment_value
    counted_items.sum { |item| item.difference.to_d * item.product.average_cost_price }
  end

  private

  def assign_count_number
    self.count_number ||= Inventory::NumberSequencer.new(business, :stock_count).next_number
  end

  def has_at_least_one_item
    errors.add(:base, :no_items) if items.reject(&:marked_for_destruction?).empty?
  end

  # The DB unique index is the hard guard; this catches duplicates among unsaved
  # worksheet rows (which the per-item uniqueness validator can't see).
  def products_are_unique
    ids = items.reject(&:marked_for_destruction?).map(&:product_id).compact
    errors.add(:base, :duplicate_product) if ids.size != ids.uniq.size
  end

  # The warehouse id comes straight from form params — never trust one that
  # belongs to another business (IP-1).
  def warehouse_in_same_business
    return if warehouse.nil? || business_id.nil?

    errors.add(:warehouse_id, :other_business) if warehouse.business_id != business_id
  end

  # An approved count changes only by being reopened (approved → in_progress,
  # Inventory::StockCountReopener); a cancelled count never changes.
  def reject_changes_when_frozen
    reopening = status_was == "approved" && will_save_change_to_status? && in_progress?
    return unless (status_was == "approved" && !reopening) || status_was == "cancelled"

    errors.add(:base, status_was == "cancelled" ? :cancelled_immutable : :approved_immutable)
    throw :abort
  end

  def reject_destroy_unless_deletable
    return if deletable?

    raise ImmutableDocument::DeletionNotAllowedError,
          "StockCount ##{id} cannot be deleted — it is past counting or has posted stock " \
          "(reopen and cancel it instead)."
  end
end
