FactoryBot.define do
  factory :payroll_adjustment do
    association :payroll_period

    user         { create(:user, business: payroll_period.business) }
    created_by   { create(:user, business: payroll_period.business) }
    business     { payroll_period.business }
    period_month { payroll_period.period_month }
    period_year  { payroll_period.period_year }
    adjustment_type { :cash_incentive }
    amount          { 500.0 }
    reason          { "Performance incentive" }
    review_status   { :pending_review }

    trait :cash_incentive do
      adjustment_type { :cash_incentive }
      amount          { 500.0 }
      reason          { "Performance incentive" }
    end

    trait :commission do
      adjustment_type { :commission }
      amount          { 500.0 }
      reason          { "Sales commission" }
    end

    trait :manual_deduction do
      adjustment_type { :manual_deduction }
      amount          { 200.0 }
      reason          { "Customer complaint penalty" }
    end

    trait :penalty do
      adjustment_type { :penalty }
      amount          { 150.0 }
      reason          { "Policy violation" }
    end

    trait :already_paid do
      already_paid    { true }
      payment_method  { "cash" }
      paid_at         { 3.days.ago }
      review_status   { :approved }
    end

    trait :approved do
      review_status { :approved }
    end
  end
end
