FactoryBot.define do
  factory :shift do
    association :business
    sequence(:name)          { |n| "Shift #{n}" }
    shift_type               { :fixed_time }
    start_time               { Time.zone.parse("09:00") }
    end_time                 { Time.zone.parse("17:00") }
    required_hours           { nil }
    overtime_rate_multiplier { 1.5 }
    active                   { true }

    trait :fixed_time do
      shift_type     { :fixed_time }
      start_time     { Time.zone.parse("09:00") }
      end_time       { Time.zone.parse("17:00") }
      required_hours { nil }
    end

    trait :hour_based do
      shift_type     { :hour_based }
      start_time     { nil }
      end_time       { nil }
      required_hours { 8.0 }
    end

    trait :overnight do
      shift_type     { :fixed_time }
      start_time     { Time.zone.parse("13:00") }
      end_time       { Time.zone.parse("01:00") }
      required_hours { nil }
    end

    trait :inactive do
      active { false }
    end
  end
end
