FactoryBot.define do
  factory :obligation_deduction do
    association :employee_obligation
    association :payroll_period

    deducted_amount  { 500.00 }
    remaining_before { 3000.00 }
    remaining_after  { 2500.00 }
  end
end
