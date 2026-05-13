FactoryBot.define do
  factory :salary_profile do
    association :user
    salary_type          { :monthly }
    base_amount          { 5_000.0 }
    overtime_multiplier  { 1.5 }
    currency             { "SAR" }
    effective_from       { 1.year.ago.to_date }
    active               { true }

    trait :monthly do
      salary_type { :monthly }
      base_amount { 5_000.0 }
    end

    trait :daily do
      salary_type { :daily }
      base_amount { 250.0 }
    end

    trait :inactive do
      active { false }
    end
  end
end
