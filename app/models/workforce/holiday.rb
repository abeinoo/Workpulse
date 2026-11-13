# A date of the business's Holiday Calendar (R6; attendance plan revision 19,
# A10, D3): an approved public or company holiday. One business-wide calendar —
# no branch-specific holidays in this phase (D3). Workforce-owned; written only
# through Scheduling::HolidayCalendar (audited). From R7, Attendance & Payroll
# reads it: a holiday is never an absence.
class Holiday < ApplicationRecord
  KINDS = %w[public company].freeze

  belongs_to :business
  belongs_to :created_by, class_name: "User"

  validates :date, presence: true, uniqueness: { scope: :business_id }
  validates :name, presence: true, length: { maximum: 120 }
  validates :kind, inclusion: { in: KINDS }
  validate :created_by_same_business

  scope :for_business, ->(business) { where(business: business) }
  scope :ordered,      -> { order(:date) }
  scope :in_year,      ->(year) { where(date: Date.new(year, 1, 1)..Date.new(year, 12, 31)) }

  def public_holiday? = kind == "public"

  private

  def created_by_same_business
    errors.add(:created_by, :other_business) if created_by && business_id && created_by.business_id != business_id
  end
end
