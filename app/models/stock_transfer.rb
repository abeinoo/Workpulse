class StockTransfer < ApplicationRecord
  include RequiresActiveWarehouse
  include ImmutableDocument
  include Voidable

  # Two posting modes (column posting_mode, fixed at creation):
  #
  # via_transit — every transfer created from the Stock Transfer redesign on
  # (decisions D1–D12):
  #
  #   draft              no reservation, no movement   (StockTransferDraftService)
  #   pending_approval   reserves its source quantities (StockTransferSubmission;
  #                      approver edits keep it pending — StockTransferEditor)
  #   awaiting_dispatch  approved: still reserves; nothing moved (StockTransferApproval)
  #   in_transit         dispatched: source OUT + transit IN posted, the
  #                      reservation consumed (StockTransferDispatch); receipts
  #                      move stock transit -> destination (StockTransferReceiving)
  #   discrepancy        the receiver closed with a shortfall; the remainder is
  #                      returned / written off (StockTransferDiscrepancyResolution)
  #   received           nothing outstanding — every dispatched unit received or resolved
  #   rejected / cancelled  reservation released, nothing moved (never after dispatch)
  #
  # "Partially received" is derived, never stored: in_transit with a receipt.
  #
  # direct — every transfer that existed before (legacy rows posted on
  # creation, and Phase 2 transfers) and any draft/pending row created as
  # direct: approval posts source OUT + destination IN at once and the status
  # becomes "approved"; only those can be voided (Inventory::DocumentVoider).
  # Never reinterpreted as a transit transfer (D11).
  #
  # Every reservation is derived from the status (Inventory::StockAvailability),
  # and every transition is a single status change under the transfer's row
  # lock, so a quantity is reserved, consumed or released exactly once.
  POSTING_MODES = %w[direct via_transit].freeze
  enum :status, { draft: "draft", pending_approval: "pending_approval", approved: "approved",
                  awaiting_dispatch: "awaiting_dispatch", in_transit: "in_transit", discrepancy: "discrepancy",
                  received: "received", rejected: "rejected", cancelled: "cancelled" }

  # posting_mode => { status_in_database (nil = new) => statuses it may move to }.
  TRANSITIONS = {
    "direct" => {
      nil                => %w[draft],
      "draft"            => %w[pending_approval cancelled],
      "pending_approval" => %w[approved rejected cancelled]
    },
    "via_transit" => {
      nil                 => %w[draft],
      "draft"             => %w[pending_approval cancelled],
      "pending_approval"  => %w[awaiting_dispatch rejected cancelled],
      "awaiting_dispatch" => %w[in_transit cancelled],
      "in_transit"        => %w[received discrepancy],
      "discrepancy"       => %w[received]
    }
  }.freeze
  # Statuses whose lines may still change (draft: the requester; pending: an
  # approver, Inventory::StockTransferEditor).
  EDITABLE_STATUSES    = %w[draft pending_approval].freeze
  # Never after dispatch (D5).
  CANCELLABLE_STATUSES = %w[draft pending_approval awaiting_dispatch].freeze
  # Statuses whose lines hold a reservation in the source warehouse.
  RESERVING_STATUSES   = %w[pending_approval awaiting_dispatch].freeze
  # Dispatched: stock is (partly) in the system transit warehouse.
  OPEN_TRANSIT_STATUSES = %w[in_transit discrepancy].freeze
  # What may change on a row in each non-editable status (besides status and
  # updated_at): only what the next workflow step records. Everything else is history.
  MUTABLE_ATTRIBUTES_BY_STATUS = {
    "awaiting_dispatch" => %w[dispatched_at dispatched_by_id dispatched_on transferred_on
                              cancelled_at cancelled_by_id cancellation_reason],
    "in_transit"        => %w[received_at],
    "discrepancy"       => %w[received_at],
    "approved"          => %w[voided_at voided_by_id void_reason] # a direct transfer's void
  }.freeze

  belongs_to :business
  belongs_to :source_warehouse,      class_name: "Warehouse"
  belongs_to :destination_warehouse, class_name: "Warehouse"
  include OperationalWarehouseReference
  operational_warehouse :source_warehouse, :destination_warehouse # never the system transit warehouse
  belongs_to :created_by,   class_name: "User", optional: true
  belongs_to :submitted_by, class_name: "User", optional: true
  belongs_to :approved_by,  class_name: "User", optional: true
  belongs_to :rejected_by,  class_name: "User", optional: true
  belongs_to :cancelled_by, class_name: "User", optional: true
  belongs_to :dispatched_by, class_name: "User", optional: true

  has_many :items, class_name: "StockTransferItem", dependent: :destroy, inverse_of: :stock_transfer
  has_many :inventory_movements, as: :source, dependent: :destroy
  # Append-only ledgers of a via-transit transfer (never deleted: ImmutableDocument).
  has_many :receipts,    class_name: "StockTransferReceipt",    dependent: :restrict_with_exception
  has_many :resolutions, class_name: "StockTransferResolution", dependent: :restrict_with_exception

  # A blank NEW line (no product picked) is ignored; an existing line is
  # always applied — an approver may change just its quantity by id.
  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:id].blank? && attrs[:product_id].blank? }

  validates :transfer_number, presence: true,
                              uniqueness: { scope: :business_id, case_sensitive: false }
  validates :transferred_on, presence: true
  validate  :has_at_least_one_item
  validate  :distinct_warehouses
  # Both ends must be active for a new transfer and for each forward step
  # (submission reserves, approval posts). Rejecting, cancelling and voiding
  # stay possible after a warehouse was deactivated.
  requires_active_warehouse :source_warehouse, :destination_warehouse,
                            transitions: { status: %w[pending_approval approved awaiting_dispatch in_transit] }
  validate  :warehouses_in_same_business,
            if: -> { will_save_change_to_source_warehouse_id? || will_save_change_to_destination_warehouse_id? }
  validates :posting_mode, inclusion: { in: POSTING_MODES }
  validate  :posting_mode_fixed, on: :update
  validate  :allowed_status_transition, if: :will_save_change_to_status?
  validate  :warehouses_fixed_after_submission, on: :update
  validate  :decided_transfer_unchanged, on: :update
  validates :rejection_reason,    presence: true, if: :rejected?
  validates :cancellation_reason, presence: true, if: :cancelled?

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(transferred_on: :desc, id: :desc) }
  scope :for_status,   ->(status) { where(status: status) if status.present? && statuses.key?(status.to_s) }
  # Transfers whose stock has moved (their movements exist), voided ones
  # included: direct transfers once approved, transit transfers once dispatched.
  scope :posted,       -> { where(status: %w[approved] + OPEN_TRANSIT_STATUSES + %w[received]) }
  # Transfers currently holding a reservation in their source warehouse.
  scope :reserving,    -> { where(status: RESERVING_STATUSES).active }
  scope :via_transit,  -> { where(posting_mode: "via_transit") }
  scope :open_in_transit, -> { where(status: OPEN_TRANSIT_STATUSES) }

  def editable?    = EDITABLE_STATUSES.include?(status_in_database) && !voided?
  def cancellable? = CANCELLABLE_STATUSES.include?(status_in_database) && !voided?
  def reserving?   = RESERVING_STATUSES.include?(status_in_database) && !voided?
  def via_transit? = posting_mode == "via_transit"
  def direct?      = posting_mode == "direct"
  def dispatched?  = dispatched_at.present?
  def open_in_transit? = OPEN_TRANSIT_STATUSES.include?(status_in_database)
  # Derived, never stored: in transit with at least one receipt.
  def partially_received? = in_transit? && receipts.any?

  # Posted on creation, before the approval workflow existed: approved with no
  # recorded approver or approval time.
  def legacy_posting? = approved? && approved_at.nil? && approved_by_id.nil?

  # Optimistic edit token (same convention as StockIssue#lock_token): every
  # save touches the row, so a form opened before another user's save is
  # refused instead of silently overwriting newer lines.
  def lock_token
    updated_at&.utc&.iso8601(6)
  end

  def total_value
    items.sum(&:total_cost)
  end

  # { product_id => total quantity } over the lines that will be saved.
  def requested_quantities
    items.reject(&:marked_for_destruction?).select(&:product_id)
         .group_by(&:product_id).transform_values { |list| list.sum { |i| i.quantity.to_d } }
  end

  # Compensating movements that undo this transfer: pull the quantity back out of
  # the destination and return it to the source.
  def reversal_entries
    items.flat_map do |item|
      [ { product: item.product, warehouse: destination_warehouse,
          direction: :out, quantity: item.quantity, unit_cost: item.unit_cost },
        { product: item.product, warehouse: source_warehouse,
          direction: :in, quantity: item.quantity, unit_cost: item.unit_cost } ]
    end
  end

  private

  def has_at_least_one_item
    errors.add(:base, :no_items) if items.reject(&:marked_for_destruction?).empty?
  end

  def distinct_warehouses
    return if source_warehouse_id.blank? || destination_warehouse_id.blank?
    errors.add(:destination_warehouse_id, :same_as_source) if source_warehouse_id == destination_warehouse_id
  end

  # Both warehouse ids come straight from form params — never trust one that
  # belongs to another business (IP-1).
  def warehouses_in_same_business
    return if business_id.nil?

    errors.add(:source_warehouse_id, :other_business) if source_warehouse && source_warehouse.business_id != business_id
    if destination_warehouse && destination_warehouse.business_id != business_id
      errors.add(:destination_warehouse_id, :other_business)
    end
  end

  def allowed_status_transition
    from = new_record? ? nil : status_in_database
    allowed = TRANSITIONS.fetch(posting_mode, {}).fetch(from, [])
    errors.add(:status, :invalid_transition, from: from || "new", to: status) unless allowed.include?(status)
  end

  def posting_mode_fixed
    errors.add(:posting_mode, :immutable) if will_save_change_to_posting_mode?
  end

  # A submitted transfer reserves stock in its source warehouse; its ends
  # never change after that (an approver edits lines and notes only).
  def warehouses_fixed_after_submission
    return if status_in_database == "draft"
    return unless will_save_change_to_source_warehouse_id? || will_save_change_to_destination_warehouse_id?

    errors.add(:base, :warehouses_fixed)
  end

  # Past the editable statuses a transfer is history: only what the next
  # workflow step records may still be written (MUTABLE_ATTRIBUTES_BY_STATUS);
  # rejected, cancelled and received rows never change.
  def decided_transfer_unchanged
    from = status_in_database
    return if EDITABLE_STATUSES.include?(from)

    allowed = MUTABLE_ATTRIBUTES_BY_STATUS.fetch(from, []) + %w[status updated_at]
    allowed -= %w[status] if from == "approved" # a direct transfer's void changes nothing else
    changed = changes_to_save.keys - allowed
    errors.add(:base, :decided_transfer_locked) if changed.any?
  end
end
