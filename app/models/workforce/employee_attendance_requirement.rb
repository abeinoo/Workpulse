# One row of an employee's effective-dated attendance requirement history
# (R3.2; roadmap §2 W, §8). Workforce-owned and append-only: rows are only ever
# inserted — by Workforce services, never by forms — and a database trigger
# refuses UPDATE and DELETE (OD-15 T2). The requirement in force on a date is
# the latest row with effective_from on or before it, ordered by
# (effective_from, id) (OD-15 T3); it is derived on read, never cached (OD-4).
#
# not_reviewed is written only by the R3.3 backfill (L11); HR changes and
# employee creation record required or not_required.
class EmployeeAttendanceRequirement < ApplicationRecord
  STATUSES = %w[required not_required not_reviewed].freeze
  SOURCES  = %w[creation hr_change backfill].freeze
  EFFECTIVE_DATE_BASES = %w[hire_date earliest_record].freeze

  belongs_to :business
  belongs_to :user
  belongs_to :changed_by, class_name: "User"

  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  validates :effective_from, presence: true
  validates :effective_date_basis, inclusion: { in: EFFECTIVE_DATE_BASES }, allow_nil: true
  validate :not_reviewed_only_from_backfill
  validate :basis_only_on_backfill
  validate :same_business

  scope :in_timeline_order, -> { order(:effective_from, :id) }

  def readonly? = persisted? || super

  def required?     = status == "required"
  def not_required? = status == "not_required"
  def not_reviewed? = status == "not_reviewed"

  private

  def not_reviewed_only_from_backfill
    errors.add(:status, :not_reviewed_backfill_only) if not_reviewed? && source != "backfill"
  end

  def basis_only_on_backfill
    errors.add(:effective_date_basis, :backfill_only) if effective_date_basis.present? && source != "backfill"
  end

  def same_business
    return if business_id.blank?

    errors.add(:user, :other_business) if user && user.business_id != business_id
    errors.add(:changed_by, :other_business) if changed_by && changed_by.business_id != business_id
  end
end
