FactoryBot.define do
  factory :permission_role do
    association :business
    sequence(:name) { |n| "Role #{n}" }
    description     { nil }
    permissions     { [] }

    trait :full_access do
      name        { "Full Access" }
      permissions { PermissionRole::ALL_PERMISSIONS }
    end

    trait :view_only do
      name        { "View Only" }
      permissions { %w[view_employees view_attendance view_payroll view_requests view_shifts view_reports] }
    end

    trait :with_manage_roles do
      permissions { %w[manage_roles] }
    end
  end
end
