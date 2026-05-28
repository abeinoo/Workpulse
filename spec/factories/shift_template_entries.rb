FactoryBot.define do
  factory :shift_template_entry do
    association :shift_template
    association :shift
    branch        { nil }
    starts_on     { Date.current }
    ends_on       { nil }
    weekday       { nil }
    employee_role { nil }
  end
end
