FactoryBot.define do
  factory :payroll_snapshot do
    association :payroll_period
    association :taken_by, factory: :user
    trigger          { "pre_regenerate" }
    employee_count   { 0 }
    total_net        { 0 }
    total_base       { 0 }
    total_overtime   { 0 }
    total_deductions { 0 }
    total_bonuses    { 0 }
    employee_details { [] }
  end
end
