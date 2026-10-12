class StockIssue < ApplicationRecord
  include ImmutableDocument
  include Voidable

  # The approval + physical-issuance workflow, shared by EVERY creation path
  # (manual form, CSV/Excel import): draft -> pending_approval -> approved ->
  # issued, with pending_approval -> rejected and draft/approved -> cancelled
  # as the alternate paths. "draft" is the entry state for a manually-created
  # issue (awaiting submission) and for an import still being resolved (a
  # single issue created up front, items appended as each import row
  # resolves); a finished import is submitted straight to pending_approval
  # (see Inventory::Imports::StockIssueImporter / StockIssueImportBatchCompleter)
  # — it never skips approval. "issued" is the only state where inventory has
  # actually moved, and it is reachable ONLY from "approved" (see
  # Inventory::StockIssueConfirmationService / StockIssuePoster, and the
  # #issued_only_from_approved validation below) — approval alone never
  # deducts stock. rejected/cancelled are terminal; there is no transition
  # back out of them.
  enum :status, { draft: "draft", pending_approval: "pending_approval", approved: "approved",
                  rejected: "rejected", issued: "issued", cancelled: "cancelled" }

  # Lines/header may change only before approval. Editing a pending_approval
  # issue withdraws it to draft (see Inventory::StockIssueEditor) — it must be
  # resubmitted, and no earlier submission counts as approval of new lines.
  EDITABLE_STATUSES = %w[draft pending_approval].freeze

  belongs_to :business
  belongs_to :warehouse
  # The branch that consumed the issued stock — feeds branch profitability.
  # Required for NEW issues (on :create) so every consumption is attributable;
  # the DB column stays nullable so pre-existing rows remain valid and voidable.
  belongs_to :branch, optional: true
  belongs_to :created_by,   class_name: "User", optional: true
  belongs_to :submitted_by, class_name: "User", optional: true
  belongs_to :approved_by,  class_name: "User", optional: true
  belongs_to :rejected_by,  class_name: "User", optional: true
  belongs_to :issued_by,    class_name: "User", optional: true
  belongs_to :cancelled_by, class_name: "User", optional: true

  has_many :items, class_name: "StockIssueItem", dependent: :destroy
  has_many :inventory_movements, as: :source, dependent: :destroy
  # The in-progress CSV import this draft belongs to, if any — used only to
  # keep an import-in-progress draft out of the normal index (see
  # .excluding_incomplete_imports). nil for every normal, human-workflow issue.
  has_one :import_batch, class_name: "StockIssueImportBatch", dependent: nil

  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:product_id].blank? }

  # issue_number is assigned in before_create (see #assign_issue_number) — the
  # DB's NOT NULL + unique index are the hard guards, so only
  # uniqueness-when-present is validated here (mirrors StockCount#count_number).
  validates :issue_number, uniqueness: { scope: :business_id, case_sensitive: false }, allow_nil: true
  validates :issued_on, presence: true
  validates :branch_id, presence: true, on: :create
  # A draft may sit with zero items while the user resolves import errors —
  # the item requirement only applies once it's actually being submitted or
  # posted. A cancelled issue is exempt too: cancellation is only ever reached
  # from draft or approved (see Inventory::StockIssueCancellation), and a
  # draft cancelled before any item was ever added must still be a valid,
  # terminal record — nothing was going to be issued anyway.
  validate  :has_at_least_one_item, unless: -> { draft? || cancelled? }
  validate  :branch_in_same_business
  validate  :issued_only_from_approved, if: -> { will_save_change_to_status?(to: "issued") }

  before_create :assign_issue_number

  scope :for_business,  ->(business)     { where(business: business) }
  scope :recent,        -> { order(issued_on: :desc, id: :desc) }
  scope :for_warehouse, ->(warehouse_id) { where(warehouse_id: warehouse_id) if warehouse_id.present? }
  scope :for_branch,    ->(branch_id)    { where(branch_id: branch_id) if branch_id.present? }
  scope :on_or_after,   ->(date)         { where(issued_on: date..) if date.present? }
  scope :on_or_before,  ->(date)         { where(issued_on: ..date) if date.present? }

  # Guarded against unknown values, same as GoodsReceipt's for_approval_status.
  scope :for_status,      ->(status)         { where(status: status) if status.present? && statuses.key?(status) }
  scope :for_creator,     ->(user_id)        { where(created_by_id: user_id) if user_id.present? }
  scope :for_approver,    ->(user_id)        { where(approved_by_id: user_id) if user_id.present? }
  scope :for_issuer,      ->(user_id)        { where(issued_by_id: user_id) if user_id.present? }

  # A draft still tied to an in-progress CSV import isn't a real document yet
  # (see StockIssueImportBatch) — it's reachable only from its batch page,
  # never from the normal stock-issues list.
  scope :excluding_incomplete_imports, -> {
    where.not(id: StockIssueImportBatch.draft.select(:stock_issue_id))
  }

  # Issue #, consumer branch, warehouse, or a product's SKU/name on any line.
  scope :search, ->(term) {
    return all if term.blank?

    t = "%#{term.to_s.strip.downcase}%"
    left_joins(:branch, :warehouse).where(
      "LOWER(stock_issues.issue_number) LIKE :t OR LOWER(branches.name) LIKE :t OR LOWER(warehouses.name) LIKE :t OR " \
      "EXISTS (SELECT 1 FROM stock_issue_items sii JOIN products p ON p.id = sii.product_id " \
      "WHERE sii.stock_issue_id = stock_issues.id AND (LOWER(p.sku) LIKE :t OR LOWER(p.name) LIKE :t))",
      t: t
    )
  }

  # Posted: the frozen ledger total. Not yet posted: an estimate at current
  # average cost (see StockIssueItem#effective_unit_cost); lines whose cost is
  # unavailable contribute nothing — flagged via #cost_unavailable?.
  def total_value
    items.sum { |item| item.effective_total_cost || 0 }
  end

  # Optimistic-concurrency token for the edit form: the row's updated_at at the
  # moment the form was rendered. Inventory::StockIssueEditor refuses a save
  # whose token no longer matches (someone else saved in between) instead of
  # silently overwriting the newer lines. Every successful edit touches the
  # row, so line-only changes advance it too.
  def lock_token
    updated_at&.utc&.iso8601(6)
  end

  def cost_estimated?
    !issued?
  end

  def cost_unavailable?
    items.any?(&:cost_unavailable?)
  end

  # ImmutableDocument's before_destroy is unconditional by default (it applies
  # to every other posted inventory document, which is exactly right for
  # them); a stock issue is the one document type with a genuine pre-workflow
  # draft state that's safe to delete outright — nothing has been submitted,
  # approved, or posted yet.
  def destroyable_as_draft?
    draft?
  end

  # Compensating movements that undo this issue: return the issued quantity to
  # the warehouse it was taken from.
  def reversal_entries
    items.map do |item|
      { product: item.product, warehouse: warehouse,
        direction: :in, quantity: item.quantity, unit_cost: item.unit_cost }
    end
  end

  private

  def assign_issue_number
    self.issue_number ||= Inventory::NumberSequencer.new(business, :stock_issue).next_number
  end

  def has_at_least_one_item
    errors.add(:base, :no_items) if items.reject(&:marked_for_destruction?).empty?
  end

  # Hard invariant behind the approval gate: stock may only be deducted for a
  # persisted, approved issue. Refuses any save that moves an issue to
  # "issued" from anything else (a new record, draft, pending_approval, …),
  # whatever the caller.
  def issued_only_from_approved
    errors.add(:base, :not_approved) unless status_in_database == "approved"
  end

  def branch_in_same_business
    return if branch.nil? || business_id.nil?

    errors.add(:branch, :invalid) if branch.business_id != business_id
  end
end
