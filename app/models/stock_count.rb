# A physical-inventory count for one warehouse. Built and edited as a DRAFT,
# then POSTED — posting generates a single stock-count Inventory Adjustment from
# the non-zero differences and freezes the count permanently.
#
# Unlike the other inventory documents (immutable from creation), a stock count
# is intentionally editable while draft; immutability kicks in once posted.
class StockCount < ApplicationRecord
  belongs_to :business
  belongs_to :warehouse
  belongs_to :created_by,       class_name: "User", optional: true
  belongs_to :posted_by,        class_name: "User", optional: true
  belongs_to :stock_adjustment, optional: true

  has_many :items, class_name: "StockCountItem", dependent: :destroy

  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:product_id].blank? }

  enum :status, { draft: "draft", posted: "posted" }

  # count_number is auto-assigned in before_create (which runs inside the save
  # transaction, so the advisory lock is held to commit); the DB NOT NULL + unique
  # index are the hard guards, so only uniqueness-when-present is validated here.
  validates :count_number, uniqueness: { scope: :business_id, case_sensitive: false }, allow_nil: true
  validates :counted_on, presence: true
  validate  :has_at_least_one_item
  validate  :products_are_unique

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(counted_on: :desc, id: :desc) }

  before_create  :assign_count_number
  # Guard rails: a posted count is permanent.
  before_update  :reject_changes_when_posted
  before_destroy :reject_destroy_when_posted, prepend: true

  def editable?
    draft?
  end

  # "Counted by" / "Posted by" — the audit trail of who did what.
  def counted_by
    created_by
  end

  def variance_total
    items.sum { |item| item.difference.to_d }
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

  # Block edits to an already-posted count, while still allowing the draft→posted
  # transition itself (status_was is still "draft" during that update).
  def reject_changes_when_posted
    return unless status_was == "posted"
    errors.add(:base, :posted_immutable)
    throw :abort
  end

  def reject_destroy_when_posted
    return unless posted?
    raise ImmutableDocument::DeletionNotAllowedError,
          "StockCount ##{id} is posted and cannot be deleted — void its adjustment to reverse it."
  end
end
