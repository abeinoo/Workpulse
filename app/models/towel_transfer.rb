# Declared/dispatch/receive lifecycle for moving towels between two branches
# (a sales branch <-> the laundry branch, or branch <-> branch directly).
# Mirrors the Till Handover "recipient explicitly accepts" pattern: dispatch
# posts ledger entries for the declared quantity, receive posts an IN entry
# for only the confirmed quantity, and any difference is surfaced as a
# discrepancy — never auto-corrected, and never turned into a loss/damage
# record. A transfer answers "what moved, from where, to where, how much was
# sent, how much arrived" — nothing else. Recording an actual loss or damage
# is a deliberate, separate action through Laundry::TowelAdjuster (see
# TowelAdjustment), never inferred from a transfer discrepancy.
#
# towel_status is the condition towels ARRIVE IN AT THE DESTINATION (dirty at
# a laundry branch, clean at a sales branch) — not a single condition for the
# whole journey. The source's own dispatch always debits its CLEAN balance
# (see Laundry::TowelTransferCreator#dispatch for why), so towel_status alone
# fully determines the receive-side ledger entry. It is always inferred
# server-side from branch types (see .infer_towel_status) — there is no
# user-facing override.
class TowelTransfer < ApplicationRecord
  belongs_to :business
  belongs_to :towel_type
  belongs_to :source_branch,      class_name: "Branch", inverse_of: :outgoing_towel_transfers
  belongs_to :destination_branch, class_name: "Branch", inverse_of: :incoming_towel_transfers
  belongs_to :created_by,    class_name: "User", optional: true
  belongs_to :dispatched_by, class_name: "User", optional: true
  belongs_to :received_by,   class_name: "User", optional: true
  belongs_to :cancelled_by,  class_name: "User", optional: true

  has_many :towel_ledger_entries, as: :source, dependent: :restrict_with_error

  enum :status,       { draft: "draft", dispatched: "dispatched", received: "received", cancelled: "cancelled" },
       default: "draft"
  enum :towel_status, { clean: "clean", dirty: "dirty" }, prefix: :towel

  validates :declared_quantity, numericality: { greater_than: 0 }
  validates :confirmed_quantity, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  # towel_status is always server-inferred from the source/destination branch
  # types (see .infer_towel_status) — there is no user-facing override, so a
  # combination that can't be inferred must fail with a clear message rather
  # than a raw NOT NULL violation from the database.
  validates :towel_status, presence: true
  validate  :branches_differ
  validate  :branches_in_same_business
  validate  :towel_type_in_same_business
  # Scoped to when either field actually changes — a record carrying
  # historical bad data (e.g. an over-receipt from before this validation
  # existed) must still be writable for unrelated updates (like a status
  # correction/reversal), not permanently locked by re-validating a value
  # nothing is trying to change.
  validate  :confirmed_quantity_not_more_than_declared,
            if: -> { confirmed_quantity_changed? || declared_quantity_changed? }

  scope :for_business, ->(business) { where(business: business) }
  scope :with_status,  ->(status)    { where(status: status) if status.present? }
  scope :for_branch,   ->(branch_id) {
    where(source_branch_id: branch_id).or(where(destination_branch_id: branch_id)) if branch_id.present?
  }
  scope :unresolved_discrepancy, -> {
    received.where.not(confirmed_quantity: nil)
            .where("confirmed_quantity <> declared_quantity")
  }

  # Infers the destination's arrival condition from branch types. Returns nil
  # when the combination isn't one of the known patterns — TowelTransfer's
  # towel_status presence validation then rejects the transfer outright;
  # there is no manual override for the caller to fall back to.
  def self.infer_towel_status(source_branch, destination_branch)
    return nil if source_branch.nil? || destination_branch.nil?
    return "dirty" if source_branch.branch_type_sales? && destination_branch.branch_type_laundry?
    return "clean" if source_branch.branch_type_laundry? && destination_branch.branch_type_sales?
    return "clean" if source_branch.branch_type_sales? && destination_branch.branch_type_sales?
    nil
  end

  # True when this transfer represents laundry produce being shipped back to
  # a sales branch — the only case where dispatch also performs the
  # dirty -> clean wash conversion (see Laundry::TowelTransferCreator).
  def wash_conversion?
    source_branch&.branch_type_laundry? && towel_clean?
  end

  # Always >= 0 — confirmed_quantity can never exceed declared_quantity (see
  # confirmed_quantity_not_more_than_declared), so a negative discrepancy
  # (receiving more than was dispatched) is impossible by construction.
  def discrepancy
    return nil unless confirmed_quantity
    declared_quantity - confirmed_quantity
  end

  private

  def branches_differ
    errors.add(:destination_branch_id, :invalid) if source_branch_id == destination_branch_id
  end

  def branches_in_same_business
    return if business_id.nil?
    errors.add(:source_branch, :invalid)      if source_branch      && source_branch.business_id != business_id
    errors.add(:destination_branch, :invalid) if destination_branch && destination_branch.business_id != business_id
  end

  def towel_type_in_same_business
    return if towel_type.nil? || business_id.nil?
    errors.add(:towel_type, :invalid) if towel_type.business_id != business_id
  end

  # Receiving more than was dispatched would create untracked stock with no
  # valid source — reject it outright rather than let it become a negative
  # discrepancy. This is defense in depth; Laundry::TowelTransferCreator#receive
  # checks this first and never posts a ledger entry when it fails.
  def confirmed_quantity_not_more_than_declared
    return if confirmed_quantity.nil?
    errors.add(:confirmed_quantity, :exceeds_declared, declared: declared_quantity) if confirmed_quantity > declared_quantity
  end
end
