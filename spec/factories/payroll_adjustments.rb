FactoryBot.define do
  factory :payroll_adjustment do
    association :payroll_period

    user         { create(:user, business: payroll_period.business) }
    created_by   { create(:user, business: payroll_period.business) }
    business     { payroll_period.business }
    period_month { payroll_period.period_month }
    period_year  { payroll_period.period_year }
    adjustment_type { :bonus }
    amount          { 500.0 }
    reason          { "Performance bonus" }
    review_status   { :pending_review }

    trait :bonus do
      adjustment_type { :bonus }
      amount          { 500.0 }
      reason          { "Performance bonus" }
    end

    trait :manual_deduction do
      adjustment_type { :manual_deduction }
      amount          { 200.0 }
      reason          { "Customer complaint penalty" }
    end
  end
end
