FactoryBot.define do
  factory :payroll_audit_log do
    association :payroll_period
    association :actor, factory: :user
    action_type { :generated }
    from_status { "draft" }
    to_status   { "draft" }
    metadata    { nil }
  end
end
