FactoryBot.define do
  factory :shift_template_entry do
    association :shift_template
    shift         { association :shift, business: shift_template.business }
    branch        { nil }
    starts_on     { Date.current }
    ends_on       { nil }
    weekday       { nil }
    employee_role { nil }
  end
end
