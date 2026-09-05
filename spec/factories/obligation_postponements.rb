FactoryBot.define do
  factory :obligation_postponement do
    association :employee_obligation
    association :performed_by, factory: :user

    postponement_type { "next_month" }
    original_month    { 8 }
    original_year     { 2026 }
    original_amount   { 2000.00 }
    target_month      { 9 }
    target_year       { 2026 }
    amount            { 2000.00 }

    trait :extend_loan do
      postponement_type { "extend_loan" }
      target_month      { 2 }
      target_year       { 2027 }
    end
  end
end
