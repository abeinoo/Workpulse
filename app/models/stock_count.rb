# A physical-inventory count for one warehouse, run as a session through four
# states:
#
#   draft        — created with every product preloaded as a row, system quantity
#                  snapshotted from live stock
#   in_progress  — counting underway; counted quantities (and difference) editable
#   completed    — counter has submitted; counts locked, awaiting approval
#   approved     — approver has approved → ONE stock-count Inventory Adjustment is
#                  generated from the non-zero differences (full audit trail,
#                  voidable) and the count is frozen permanently
#
# Counting (draft/in_progress) is intentionally editable; completed is read-only
# and approved is immutable. Approval is a separate, higher-trust action
# (segregation of duties) handled by Inventory::StockCountApprover.
class StockCount < ApplicationRecord
  belongs_to :business
  belongs_to :warehouse
  belongs_to :created_by,       class_name: "User", optional: true
  belongs_to :completed_by,     class_name: "User", optional: true
  belongs_to :approved_by,      class_name: "User", optional: true
  belongs_to :stock_adjustment, optional: true, inverse_of: :source_stock_count

  has_many :items, class_name: "StockCountItem", dependent: :destroy

  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:product_id].blank? }

  enum :status, { draft: "draft", in_progress: "in_progress", completed: "completed", approved: "approved" }

  # count_number is auto-assigned in before_create (which runs inside the save
  # transaction, so the advisory lock is held to commit); the DB NOT NULL + unique
  # index are the hard guards, so only uniqueness-when-present is validated here.
  validates :count_number, uniqueness: { scope: :business_id, case_sensitive: false }, allow_nil: true
  validates :counted_on, presence: true
  validate  :has_at_least_one_item
  validate  :products_are_unique
  validate  :warehouse_in_same_business, if: :will_save_change_to_warehouse_id?

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(counted_on: :desc, id: :desc) }

  before_create  :assign_count_number
  # Guard rails: an approved count is permanent.
  before_update  :reject_changes_when_approved
  before_destroy :reject_destroy_unless_draft, prepend: true

  # Counts may only be edited while the session is still being worked on.
  def editable_counts?
    draft? || in_progress?
  end

  # "Counted by" / "Approved by" — the audit trail of who did what.
  def counted_by
    created_by
  end

  # draft → in_progress on the first save of counted quantities.
  def start_counting!(user)
    return unless draft?
    update!(status: :in_progress, started_at: Time.current, created_by: created_by || user)
  end

  # in_progress → completed: counter submits for approval.
  def mark_completed!(user)
    return false unless in_progress?
    update!(status: :completed, completed_at: Time.current, completed_by: user)
  end

  # completed → in_progress: approver sends it back for recount.
  def reopen!
    return false unless completed?
    update!(status: :in_progress, completed_at: nil, completed_by: nil)
  end

  # ── Counting progress ────────────────────────────────────────────────────
  def counted_items      = items.select(&:counted?)
  def total_products     = items.size
  def counted_products   = counted_items.size
  def remaining_products = total_products - counted_products
  alias_method :uncounted_count, :remaining_products

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

  # Block edits to an already-approved count, while still allowing the
  # completed→approved transition itself (status_was is "completed" during it).
  def reject_changes_when_approved
    return unless status_was == "approved"
    errors.add(:base, :approved_immutable)
    throw :abort
  end

  def reject_destroy_unless_draft
    return if draft?
    raise ImmutableDocument::DeletionNotAllowedError,
          "StockCount ##{id} is past draft and cannot be deleted — void its adjustment to reverse it."
  end
end
