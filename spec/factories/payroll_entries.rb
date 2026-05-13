FactoryBot.define do
  factory :payroll_entry do
    association :payroll_period
    association :user
    salary_type       { "monthly" }
    base_salary       { 5_000.0 }
    working_days      { 22 }
    days_worked       { 22 }
    total_deductions  { 0.0 }
    total_overtime    { 0.0 }
    total_bonuses     { 0.0 }
    advances_deducted { 0.0 }
    net_salary        { 5_000.0 }
    status            { :draft }

    trait :with_deductions do
      total_deductions { 200.0 }
      net_salary       { 4_800.0 }
    end

    trait :with_overtime do
      total_overtime { 300.0 }
      net_salary     { 5_300.0 }
    end

    trait :approved do
      status { :approved }
    end
  end
end
