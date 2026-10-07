class Supplier < ApplicationRecord
  belongs_to :business

  has_many :goods_receipts, dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 150 }
  validates :primary_mobile, length: { maximum: 30 }, allow_blank: true
  validates :secondary_mobile, length: { maximum: 30 }, allow_blank: true
  validates :latitude,  numericality: { greater_than_or_equal_to: -90,  less_than_or_equal_to: 90 },  allow_nil: true
  validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true

  scope :for_business, ->(business) { where(business: business) }
  scope :ordered,      -> { order(:name) }

  def map_location?
    latitude.present? && longitude.present?
  end
end
