FactoryBot.define do
  factory :employee_obligation do
    association :user
    association :business
    association :created_by, factory: :user

    obligation_type    { "cash_loan" }
    sequence(:title)   { |n| "Loan #{n}" }
    total_amount       { 3000.00 }
    remaining_amount   { 3000.00 }
    installment_amount { 500.00 }
    installments_count { (total_amount.to_f / installment_amount.to_f).ceil }
    start_month        { Date.current.month }
    start_year         { Date.current.year }
    status             { "active" }
    auto_deduct        { true }

    trait :paused do
      status { "paused" }
    end

    trait :completed do
      status           { "completed" }
      remaining_amount { 0.00 }
    end

    trait :cancelled do
      status { "cancelled" }
    end

    trait :open_ended do
      end_month { nil }
      end_year  { nil }
    end

    trait :with_end_date do
      end_month { (Date.current >> 5).month }
      end_year  { (Date.current >> 5).year }
    end

    trait :manual_deduct do
      auto_deduct { false }
    end
  end
end
