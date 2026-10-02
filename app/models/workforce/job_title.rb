# A business's managed job titles (المسمى الوظيفي) — the single source of truth
# for the job-title dropdown on the employee form and on employee data
# requests. Employees keep the chosen name in users.job_title.
#
# Soft-delete via #active: a deactivated title disappears from the dropdown
# but employees who already hold it keep it.
class JobTitle < ApplicationRecord
  belongs_to :business

  # Same whitespace rules as Department and the backfill.
  normalizes :name, with: ->(v) { v.to_s.strip.gsub(/\s+/, " ").presence }

  validates :name, presence: true,
                   length: { maximum: 100 },
                   uniqueness: { scope: :business_id, case_sensitive: false }

  scope :active,  -> { where(active: true) }
  scope :ordered, -> { order(:name) }
  scope :for_business, ->(business) { where(business: business) }

  # Dropdown names for a business: active titles, plus `current` when it is set
  # but no longer active (so editing an employee never silently drops it).
  def self.options_for(business, current: nil)
    names = for_business(business).active.ordered.pluck(:name)
    names.unshift(current) if current.present? && names.none? { |n| n.casecmp?(current) }
    names
  end

  # True when `name` is an active title of `business` (case-insensitive).
  def self.selectable?(business_id, name)
    where(business_id: business_id, active: true).where("lower(name) = lower(?)", name.to_s).exists?
  end
end
