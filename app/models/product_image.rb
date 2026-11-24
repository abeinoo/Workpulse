# One image of a product's gallery. The product's images are ordered by
# position (1 = first); the first is the product's primary image, shown
# wherever the product's image appears (Product#primary_image, the product
# thumbnail helper). Written only by Inventory::ProductGalleryUpdater.
class ProductImage < ApplicationRecord
  include Attachable

  MAX_PER_PRODUCT = 12

  belongs_to :business
  belongs_to :product, inverse_of: :images

  has_one_attached :file
  validates_attachment :file,
    content_types: Attachable::IMAGE_CONTENT_TYPES,
    max_size:      Attachable::DEFAULT_MAX_SIZE

  validates :position, numericality: { only_integer: true, greater_than: 0 }
  validate :file_attached
  validate :product_in_same_business

  before_validation { self.business_id ||= product&.business_id }

  private

  def file_attached
    errors.add(:file, :blank) unless file.attached?
  end

  def product_in_same_business
    return if product.nil? || business_id.nil?

    errors.add(:product, :invalid) if product.business_id != business_id
  end
end
