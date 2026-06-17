class ProductVariant < ApplicationRecord
  belongs_to :product
  has_many :product_barcodes, foreign_key: :variant_id,
                              inverse_of: :product_variant,
                              dependent: :nullify

  validates :name, presence: true, length: { maximum: 200 }
  validates :sku,  length: { maximum: 80 }, allow_blank: true
  validates :sku,  uniqueness: { scope: :product_id, case_sensitive: false },
                   if: -> { sku.present? }

  scope :active,  -> { where(active: true) }
  scope :ordered, -> { order(:position, :name) }
end
