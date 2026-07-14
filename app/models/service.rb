# Minimal salon service catalog. Today this only backs the standalone
# expected_towel_usage analytical field — it is intentionally NOT wired to
# PosTransaction (no per-service line items exist there yet), so
# "expected towel usage" stays a manual/analytical figure until POS import can
# reliably supply a service breakdown.
class Service < ApplicationRecord
  belongs_to :business

  validates :name, presence: true, length: { maximum: 150 },
                   uniqueness: { scope: :business_id, case_sensitive: false }
  validates :expected_towel_usage, numericality: { greater_than_or_equal_to: 0 }

  scope :for_business, ->(business) { where(business: business) }
  scope :active,       -> { where(active: true) }
end
