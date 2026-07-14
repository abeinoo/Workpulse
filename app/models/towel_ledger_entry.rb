# Immutable ledger entry — the single source of truth for reusable-towel
# quantities, mirroring InventoryMovement's design. Current balance for a
# (towel_type, branch, status) is SUM(in) - SUM(out) over these rows, always
# derived (see Laundry::TowelBalances), never cached.
#
# There is no "in_transit" or "in_laundry" status: a towel's location is
# always a concrete Branch (including the laundry's own branch), and
# "in transit" is derived from open TowelTransfer rows, not stored here —
# state is derived from data shape, per CLAUDE.md's project philosophy.
class TowelLedgerEntry < ApplicationRecord
  belongs_to :business
  belongs_to :towel_type
  belongs_to :branch
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :source, polymorphic: true, optional: true

  DIRECTIONS = %w[in out].freeze
  STATUSES   = %w[clean dirty damaged disposed lost].freeze
  REASONS    = %w[purchased_new towel_transfer_dispatch towel_transfer_receipt
                  wash_input wash_output damage disposal adjustment reversal loss].freeze

  enum :direction, { in: "in", out: "out" }, prefix: true
  enum :status,    STATUSES.index_with(&:itself), prefix: true

  validates :reason, inclusion: { in: REASONS }
  validates :quantity, numericality: { greater_than: 0 }
  validates :occurred_at, presence: true
  validate  :towel_type_and_branch_in_same_business

  scope :for_business, ->(business) { where(business: business) }
  scope :chronological, -> { order(:occurred_at, :id) }
  scope :for_branch, ->(branch_id) { where(branch_id: branch_id) if branch_id.present? }

  # Signed quantity: positive for IN, negative for OUT — used by balance sums.
  def signed_quantity
    direction_in? ? quantity : -quantity
  end

  private

  def towel_type_and_branch_in_same_business
    return if towel_type.nil? || business_id.nil?
    errors.add(:towel_type, :invalid) if towel_type.business_id != business_id
    errors.add(:branch, :invalid) if branch && branch.business_id != business_id
  end
end
