class GoodsReceipt < ApplicationRecord
  include ImmutableDocument
  include Voidable
  include Attachable
  include Settleable

  # Only "employee_custody" is wired up to actually move money. The rest are
  # placeholders reserved on the selector so the funding-source UI doesn't
  # need to change shape when they're implemented.
  FUNDING_SOURCE_KINDS = %w[employee_custody supplier_credit company_cash bank_account].freeze
  FUNDING_SOURCE_TYPES = %w[CustodyAccount].freeze

  enum :status, { draft: "draft", confirmed: "confirmed" }

  # Approval (a purchasing decision — "I approve this purchase") is entirely
  # independent from the status enum above (an inventory event — "the goods
  # were physically received"). prefix: :approval avoids colliding with
  # status's draft?/confirmed? methods. A receipt may only be confirmed once
  # approval_status is "approved" — see Inventory::GoodsReceiptConfirmationService.
  # "cancelled" is terminal: set by Inventory::GoodsReceiptVoider when a receipt
  # that never reached an approval decision (draft / pending_approval) is
  # cancelled, so a voided receipt is never left "awaiting approval". Approved
  # and rejected decisions are history and are kept as-is on void.
  enum :approval_status, { draft: "draft", pending_approval: "pending_approval",
                           approved: "approved", rejected: "rejected", cancelled: "cancelled" },
       prefix: :approval

  # Approval states that end in "cancelled" when the receipt is voided.
  UNDECIDED_APPROVAL_STATUSES = %w[draft pending_approval].freeze

  belongs_to :business
  belongs_to :warehouse
  belongs_to :supplier,   optional: true
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :confirmed_by, class_name: "User", optional: true
  belongs_to :decided_by, class_name: "User", optional: true
  belongs_to :funding_source, polymorphic: true, optional: true
  # Optional: set only when this receipt was created from an approved
  # Purchase Request (see Inventory::PurchaseRequestsController#new via
  # GoodsReceiptsController#new). nil for every manually-created and every
  # historical receipt — never required.
  belongs_to :purchase_request, optional: true

  has_many :items, class_name: "GoodsReceiptItem", dependent: :destroy
  has_many :inventory_movements, as: :source, dependent: :destroy
  has_many :custody_transactions, as: :source, dependent: :restrict_with_error

  # Supplier invoice(s) for this receipt — kept permanently for the audit trail.
  has_many_attached :invoices

  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:product_id].blank? }

  before_validation :assign_receipt_number, on: :create

  validates :receipt_number, presence: true,
                             uniqueness: { scope: :business_id, case_sensitive: false }
  validates :received_on, presence: true
  validates :funding_source_kind, inclusion: { in: FUNDING_SOURCE_KINDS }
  validate  :has_at_least_one_item
  validate  :invoices_acceptable
  validate  :funding_source_matches_kind
  validate  :funding_source_type_whitelisted
  validate  :purchase_request_supplier_matches
  validate  :supplier_in_same_business
  validate  :warehouse_in_same_business, if: :will_save_change_to_warehouse_id?

  scope :for_business,  ->(business)     { where(business: business) }
  scope :recent,        -> { order(received_on: :desc, id: :desc) }
  scope :for_warehouse, ->(warehouse_id) { where(warehouse_id: warehouse_id) if warehouse_id.present? }
  scope :for_supplier,  ->(supplier_id)  { where(supplier_id: supplier_id) if supplier_id.present? }
  scope :on_or_after,   ->(date)         { where(received_on: date..) if date.present? }
  scope :on_or_before,  ->(date)         { where(received_on: ..date) if date.present? }

  # Guarded against unknown values (e.g. a stale/tampered query param) —
  # falls through to no-op rather than raising on an invalid enum value.
  scope :for_approval_status, ->(status) { where(approval_status: status) if status.present? && approval_statuses.key?(status) }

  # Receiving status is derived (see InventoryHelper#goods_receipt_receipt_status),
  # not a stored column — mirror that same derivation at the query level so the
  # filter matches exactly what the "Receiving Status" badge shows.
  scope :for_receiving_status, ->(status) {
    case status
    when "received"       then confirmed.active
    when "not_received"   then draft.active.where.not(approval_status: "rejected")
    when "not_receivable" then draft.active.approval_rejected
    when "voided"         then voided
    end
  }

  # Receiving (inventory) status, derived — never stored:
  #   voided         — cancelled/voided (approval is then cancelled, approved or rejected history)
  #   received       — confirmed: goods physically received
  #   not_receivable — approval rejected: cannot be received unless resubmitted and approved
  #   not_received   — awaiting approval or approved, goods not yet received
  # Receiving is all-or-nothing (draft → confirmed); there is no partial state.
  # for_receiving_status mirrors this exactly.
  def receiving_status
    return "voided"         if voided?
    return "received"       if confirmed?
    return "not_receivable" if approval_rejected?

    "not_received"
  end

  def total_value
    items.sum(&:total_cost)
  end

  def employee_custody_funded?
    funding_source_kind == "employee_custody"
  end

  # Company cash / bank account pay the supplier at approval like custody
  # does, but through no modeled account: the settlement row carries the
  # source_kind and a nil funding_source (see FinancialSettlement). Only
  # supplier_credit leaves a payable to be settled later.
  def accountless_payment_funded?
    FinancialSettlement::ACCOUNTLESS_SOURCE_KINDS.include?(funding_source_kind)
  end

  # Settleable's required hook: the amount considered "fully settled".
  alias_method :settlement_total, :total_value

  # Compensating movements that undo this receipt: remove what was received from
  # the warehouse it landed in.
  def reversal_entries
    items.map do |item|
      { product: item.product, warehouse: warehouse,
        direction: :out, quantity: item.quantity, unit_cost: item.unit_cost }
    end
  end

  private

  def assign_receipt_number
    self.receipt_number = Inventory::NumberSequencer.new(business, :goods_receipt).next_number if receipt_number.blank?
  end

  def has_at_least_one_item
    errors.add(:base, :no_items) if items.reject(&:marked_for_destruction?).empty?
  end

  # funding_source is resolved server-side from the acting user (see
  # Inventory::GoodsReceiptDraftService), so a missing one under Employee
  # Custody means that user has no active custody account — say exactly that,
  # not "funding source must be selected" (the kind IS selected).
  def funding_source_matches_kind
    if employee_custody_funded?
      errors.add(:base, :no_custody_account) if funding_source.nil?
    elsif funding_source.present?
      errors.add(:funding_source, :must_be_blank)
    end
  end

  def funding_source_type_whitelisted
    return if funding_source_type.nil?

    errors.add(:funding_source_type, :invalid) unless FUNDING_SOURCE_TYPES.include?(funding_source_type)
  end

  # A receipt created from a Purchase Request that names a supplier must buy
  # from that same supplier — never a different one, however the form was
  # tampered with. A request without a supplier fixes nothing: each receipt
  # records its own actual supplier (or none), so one request's goods may come
  # from several suppliers.
  def purchase_request_supplier_matches
    return if purchase_request.nil?

    if purchase_request.supplier_id.present? && supplier_id != purchase_request.supplier_id
      errors.add(:supplier, :must_match_purchase_request)
    end
    errors.add(:purchase_request, :invalid) if purchase_request.business_id != business_id
  end

  # The supplier must belong to the receipt's business on every path, with or
  # without a Purchase Request (SEC-P6-1) — the PurchaseRequest rule of the
  # same name.
  def supplier_in_same_business
    return if supplier.nil? || business_id.nil?

    errors.add(:supplier, :invalid) if supplier.business_id != business_id
  end

  # The warehouse id comes straight from form params — never trust one that
  # belongs to another business (IP-1).
  def warehouse_in_same_business
    return if warehouse.nil? || business_id.nil?

    errors.add(:warehouse_id, :other_business) if warehouse.business_id != business_id
  end

  # has_many_attached can't use the Attachable.validates_attachment helper
  # (that one targets a single attachment), so validate each blob here.
  def invoices_acceptable
    return unless invoices.attached?

    invoices.blobs.each do |blob|
      unless Attachable::DOCUMENT_CONTENT_TYPES.include?(blob.content_type)
        human_types = Attachable::DOCUMENT_CONTENT_TYPES
          .map { |t| Attachable::CONTENT_TYPE_LABELS.fetch(t, t.split("/").last.upcase) }
          .join(", ")
        errors.add(:invoices, :invalid_content_type,
                   message: I18n.t("attachments.errors.invalid_content_type",
                                   types: human_types,
                                   default: "must be one of: #{human_types}"))
      end

      if blob.byte_size > Attachable::DEFAULT_DOCUMENT_SIZE
        human_max = ActiveSupport::NumberHelper.number_to_human_size(Attachable::DEFAULT_DOCUMENT_SIZE)
        errors.add(:invoices, :file_too_large,
                   message: I18n.t("attachments.errors.file_too_large",
                                   max: human_max,
                                   default: "must be smaller than #{human_max}"))
      end
    end
  end
end
