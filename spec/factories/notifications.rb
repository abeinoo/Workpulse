FactoryBot.define do
  factory :notification do
    association :user
    event_type { "payroll_finalized" }
    title      { "Payroll finalized — May 2026" }
    body       { "The May 2026 payroll has been finalized." }
    severity   { "info" }
    data       { {} }
    read_at    { nil }

    trait :unread do
      read_at { nil }
    end

    trait :read do
      read_at { 1.hour.ago }
    end

    trait :warning do
      severity { "warning" }
    end

    trait :danger do
      severity { "danger" }
    end

    trait :success do
      severity { "success" }
    end
  end
end
