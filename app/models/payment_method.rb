class PaymentMethod < ApplicationRecord
  belongs_to :business

  SETTLEMENT_TYPES = %w[cash card ewallet voucher other].freeze

  enum :settlement_type, {
    cash:    "cash",
    card:    "card",
    ewallet: "ewallet",
    voucher: "voucher",
    other:   "other"
  }

  validates :name, presence: true, length: { maximum: 80 },
                   uniqueness: { scope: :business_id, case_sensitive: false }
  validates :settlement_type, inclusion: { in: SETTLEMENT_TYPES }

  scope :for_business, ->(business) { where(business: business) }
  scope :active,       -> { where(active: true) }
  scope :ordered,      -> { order(:position, :name) }

  # Methods with settlement_type 'cash' participate in the ATM deposit workflow.
  def cash_like? = cash?

  def display_name(locale = I18n.locale)
    locale.to_s == "ar" && name_ar.present? ? name_ar : name
  end
end
