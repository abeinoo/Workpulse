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
  belongs_to :source_branch,      class_name: "Branch", inverse_of: :outgoing_towel_transfers
  belongs_to :destination_branch, class_name: "Branch", inverse_of: :incoming_towel_transfers
  belongs_to :created_by,    class_name: "User", optional: true
  belongs_to :dispatched_by, class_name: "User", optional: true
  belongs_to :received_by,   class_name: "User", optional: true
  belongs_to :cancelled_by,  class_name: "User", optional: true

  has_many :towel_ledger_entries, as: :source, dependent: :restrict_with_error
  has_many :items, class_name: "TowelTransferItem", dependent: :destroy, inverse_of: :towel_transfer

  accepts_nested_attributes_for :items, allow_destroy: true,
                                        reject_if: ->(attrs) { attrs[:towel_type_id].blank? }

  enum :status,       { draft: "draft", dispatched: "dispatched", received: "received", cancelled: "cancelled" },
       default: "draft"
  enum :towel_status, { clean: "clean", dirty: "dirty" }, prefix: :towel

  # towel_status is always server-inferred from the source/destination branch
  # types (see .infer_towel_status) — there is no user-facing override, so a
  # combination that can't be inferred must fail with a clear message rather
  # than a raw NOT NULL violation from the database.
  validates :towel_status, presence: true
  validate  :branches_differ
  validate  :branches_in_same_business
  validate  :has_at_least_one_item
  # An inactive branch takes no new transfer (BUG-029): checked whenever a
  # branch reference is written. A transfer created before the deactivation
  # may still be dispatched from an inactive source, but never to an inactive
  # destination; receiving or cancelling one already in transit stays allowed.
  validate  :branches_active,
            if: -> { will_save_change_to_source_branch_id? || will_save_change_to_destination_branch_id? }
  validate  :destination_active, if: -> { will_save_change_to_status?(to: "dispatched") }

  scope :for_business, ->(business) { where(business: business) }
  scope :with_status,  ->(status)    { where(status: status) if status.present? }
  scope :for_branch,   ->(branch_id) {
    where(source_branch_id: branch_id).or(where(destination_branch_id: branch_id)) if branch_id.present?
  }
  # Any transfer with at least one received line item whose confirmed
  # quantity differs from what was declared (mirrors StockIssue.search's
  # EXISTS-subquery style for a per-line condition surfaced at the header).
  scope :unresolved_discrepancy, -> {
    received.where(
      "EXISTS (SELECT 1 FROM towel_transfer_items ti WHERE ti.towel_transfer_id = towel_transfers.id " \
      "AND ti.confirmed_quantity IS NOT NULL AND ti.confirmed_quantity <> ti.declared_quantity)"
    )
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

  # Total across every line item — nil until the transfer has actually been
  # received (mirrors the single-item original: no discrepancy concept exists
  # before receipt). Never negative once received, since no individual item's
  # discrepancy can be (see TowelTransferItem#discrepancy).
  def discrepancy
    return nil unless received?
    items.sum { |item| item.discrepancy || 0 }
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

  def branches_active
    errors.add(:source_branch, :branch_inactive)      if source_branch      && !source_branch.active?
    errors.add(:destination_branch, :branch_inactive) if destination_branch && !destination_branch.active?
  end

  def destination_active
    errors.add(:destination_branch, :branch_inactive) if destination_branch && !destination_branch.active?
  end

  def has_at_least_one_item
    errors.add(:base, :no_items) if items.reject(&:marked_for_destruction?).empty?
  end
end
