class ObligationPostponement < ApplicationRecord
  TYPES = %w[next_month extend_loan].freeze

  belongs_to :employee_obligation
  belongs_to :performed_by, class_name: "User"

  enum :postponement_type, {
    next_month:  "next_month",
    extend_loan: "extend_loan"
  }

  validates :postponement_type, inclusion: { in: TYPES }
  validates :original_month, :target_month, inclusion: { in: 1..12 }
  validates :original_year, :target_year,
            presence: true, numericality: { only_integer: true, greater_than: 2000 }
  validates :original_amount, :amount, numericality: { greater_than: 0 }
  validates :original_year, uniqueness: { scope: [ :employee_obligation_id, :original_month ] }

  def original_label
    "#{I18n.t("date.month_names")[original_month]} #{original_year}"
  end

  def target_label
    "#{I18n.t("date.month_names")[target_month]} #{target_year}"
  end
end
