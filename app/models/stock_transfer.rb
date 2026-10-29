class StockTransfer < ApplicationRecord
  include ImmutableDocument
  include Voidable

  belongs_to :business
  belongs_to :source_warehouse,      class_name: "Warehouse"
  belongs_to :destination_warehouse, class_name: "Warehouse"
  belongs_to :created_by, class_name: "User", optional: true

  has_many :items, class_name: "StockTransferItem", dependent: :destroy
  has_many :inventory_movements, as: :source, dependent: :destroy

  accepts_nested_attributes_for :items,
                                allow_destroy: true,
                                reject_if:     ->(attrs) { attrs[:product_id].blank? }

  validates :transfer_number, presence: true,
                              uniqueness: { scope: :business_id, case_sensitive: false }
  validates :transferred_on, presence: true
  validate  :has_at_least_one_item
  validate  :distinct_warehouses
  validate  :warehouses_in_same_business,
            if: -> { will_save_change_to_source_warehouse_id? || will_save_change_to_destination_warehouse_id? }

  scope :for_business, ->(business) { where(business: business) }
  scope :recent,       -> { order(transferred_on: :desc, id: :desc) }

  def total_value
    items.sum(&:total_cost)
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
end
