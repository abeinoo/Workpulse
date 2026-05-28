FactoryBot.define do
  factory :shift_rule_profile do
    association :business
    sequence(:name) { |n| "Rule Profile #{n}" }
    description              { nil }
    expected_work_hours      { nil }
    break_minutes            { nil }
    late_grace_minutes       { nil }
    early_leave_grace_minutes { nil }
    overtime_enabled         { true }
    overtime_multiplier      { nil }
    active                   { true }

    trait :ramadan do
      name                     { "Ramadan Schedule" }
      expected_work_hours      { 6.0 }
      late_grace_minutes       { 10 }
      early_leave_grace_minutes { 10 }
    end

    trait :overtime_disabled do
      overtime_enabled { false }
    end

    trait :inactive do
      active { false }
    end
  end
end
