# A real washing operation. draft -> in_progress -> completed (or cancelled).
# Completion posts the towel ledger entries (dirty consumed, clean/damaged/
# disposed produced) and enforces the conservation invariant:
#   input_quantity == output_clean_quantity + damaged_quantity + disposed_quantity
# Completed batches are Voidable, never destroyed — reversal posts compensating
# ledger entries, matching ImmutableDocument's convention used elsewhere.
class LaundryBatch < ApplicationRecord
  include Voidable

  belongs_to :business
  belongs_to :laundry_branch, class_name: "Branch"
  belongs_to :towel_type
  belongs_to :operator,     class_name: "User", optional: true
  belongs_to :created_by,   class_name: "User", optional: true
  belongs_to :completed_by, class_name: "User", optional: true

  has_many :consumptions, class_name: "LaundryBatchConsumption", dependent: :restrict_with_error
  has_many :towel_ledger_entries, as: :source, dependent: :restrict_with_error

  enum :status, { draft: "draft", in_progress: "in_progress", completed: "completed", cancelled: "cancelled" },
       default: "draft"

  validates :batch_number, presence: true, uniqueness: { scope: :business_id, case_sensitive: false }
  validates :input_quantity, numericality: { greater_than: 0 }, if: -> { in_progress? || completed? }
  validates :output_clean_quantity, :damaged_quantity, :disposed_quantity,
            numericality: { greater_than_or_equal_to: 0 }
  validate  :laundry_branch_in_same_business
  # The towel type and operator ids come from the batch form's params — never
  # trust one that belongs to another business (BUG-034).
  validate  :towel_type_and_operator_in_same_business,
            if: -> { will_save_change_to_towel_type_id? || will_save_change_to_operator_id? }
  # A new batch is never opened at an inactive branch (BUG-029); existing
  # batches there keep their lifecycle and history.
  validate  :laundry_branch_active, if: :will_save_change_to_laundry_branch_id?
  validate  :conservation_balances, if: :completed?

  scope :for_business, ->(business) { where(business: business) }
  scope :with_status,  ->(status)   { where(status: status) if status.present? }

  def total_material_cost
    consumptions.sum(:total_cost_snapshot)
  end

  private

  def laundry_branch_in_same_business
    return if laundry_branch.nil? || business_id.nil?
    errors.add(:laundry_branch, :invalid) if laundry_branch.business_id != business_id
  end

  def towel_type_and_operator_in_same_business
    return if business_id.nil?

    errors.add(:towel_type_id, :other_business) if towel_type && towel_type.business_id != business_id
    errors.add(:operator_id, :other_business)   if operator && operator.business_id != business_id
  end

  def laundry_branch_active
    errors.add(:laundry_branch, :branch_inactive) if laundry_branch && !laundry_branch.active?
  end

  # Arithmetic conservation, not a business rule: what went in as dirty must be
  # fully accounted for as clean, damaged, or disposed by completion time.
  def conservation_balances
    accounted = output_clean_quantity + damaged_quantity + disposed_quantity
    return if accounted == input_quantity

    errors.add(:base, :conservation_mismatch,
               input: input_quantity, accounted: accounted)
  end
end
