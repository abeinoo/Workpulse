# Explicit manual correction record — never a silent balance edit. Captures
# the original value, the signed adjustment quantity, who made it, and why.
# Posts one or more TowelLedgerEntry rows (see Laundry::TowelAdjuster).
#
# adjustment_type distinguishes the operator's *intent*, independent of
# `status` (which ledger bucket got the balance-changing entry):
#   - "correction" (default) — a free-form manual correction of any single
#     ledger bucket (clean/dirty/damaged/disposed/lost), exactly as before
#     this field existed. `status` is whatever bucket the user picked.
#   - "lost"/"damaged" — the guided path for recording an actual loss or
#     damage. The user only picks branch/towel type/quantity/reason; the
#     ledger bucket (`status`) is always set to the branch's OPERATIONAL
#     balance (dirty at the laundry, clean at a sales branch — see
#     Laundry::TowelBalances#operational), which this reduces directly,
#     while a second ledger entry (see towel_ledger_entries) records the same
#     quantity into the "lost"/"damaged" tracking bucket for the Towel
#     Balances dashboard — mirroring what a laundry->sales-branch transfer's
#     wash conversion used to do inline, now an explicit, separate action.
class TowelAdjustment < ApplicationRecord
  belongs_to :business
  belongs_to :towel_type
  belongs_to :branch
  belongs_to :created_by, class_name: "User", optional: true

  has_many :towel_ledger_entries, as: :source, dependent: :restrict_with_error

  enum :status, TowelLedgerEntry::STATUSES.index_with(&:itself)
  enum :adjustment_type, { correction: "correction", lost: "lost", damaged: "damaged" },
       prefix: :type, default: "correction"

  # original_quantity is a factual snapshot of whatever the ledger showed
  # right before this correction — it documents reality, so it must be
  # allowed to be negative (e.g. correcting a balance that went negative due
  # to a since-fixed bug elsewhere). The real business invariant — the
  # corrected balance can't be negative — is enforced by
  # resulting_quantity_not_negative below.
  validates :original_quantity, numericality: true
  validates :adjustment_quantity, numericality: { other_than: 0 }
  validates :reason, presence: true
  validate  :towel_type_and_branch_in_same_business
  validate  :resulting_quantity_not_negative
  # No correction, loss or damage record at an inactive branch (BUG-029) —
  # there is no closing-correction exception.
  validate  :branch_active, on: :create

  scope :for_business, ->(business) { where(business: business) }

  def resulting_quantity
    original_quantity + adjustment_quantity
  end

  private

  def towel_type_and_branch_in_same_business
    return if business_id.nil?
    errors.add(:towel_type, :invalid) if towel_type && towel_type.business_id != business_id
    errors.add(:branch, :invalid)     if branch && branch.business_id != business_id
  end

  def branch_active
    errors.add(:branch, :branch_inactive) if branch && !branch.active?
  end

  def resulting_quantity_not_negative
    return if original_quantity.nil? || adjustment_quantity.nil?
    errors.add(:adjustment_quantity, :would_go_negative) if resulting_quantity.negative?
  end
end
