class GoodsReceipt < ApplicationRecord
  include ImmutableDocument
  include Voidable
  include Attachable

  belongs_to :business
  belongs_to :warehouse
  belongs_to :supplier,   optional: true
  belongs_to :created_by, class_name: "User", optional: true

  has_many :items, class_name: "GoodsReceiptItem", dependent: :destroy
  has_many :inventory_movements, as: :source, dependent: :destroy

  # Supplier invoice(s) for this receipt — kept permanently for the audit trail.
  has_many_attached :invoices

  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:product_id].blank? }

  validates :receipt_number, presence: true,
                             uniqueness: { scope: :business_id, case_sensitive: false }
  validates :received_on, presence: true
  validate  :has_at_least_one_item
  validate  :invoices_acceptable

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(received_on: :desc, id: :desc) }

  def total_value
    items.sum(&:total_cost)
  end

  # Compensating movements that undo this receipt: remove what was received from
  # the warehouse it landed in.
  def reversal_entries
    items.map do |item|
      { product: item.product, warehouse: warehouse,
        direction: :out, quantity: item.quantity, unit_cost: item.unit_cost }
    end
  end

  private

  def has_at_least_one_item
    errors.add(:base, :no_items) if items.reject(&:marked_for_destruction?).empty?
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
