FactoryBot.define do
  factory :user do
    association :business
    first_name            { Faker::Name.first_name }
    last_name             { Faker::Name.last_name }
    sequence(:email)      { |n| "user#{n}@example.com" }
    # 14-char unique identity card number — required by User validation.
    sequence(:identity_card_number) { |n| (10**13 + n).to_s }
    password              { "password123" }
    password_confirmation { "password123" }
    active                { true }

    # Ownership: sets this user as the business owner.
    # Use :owner (or the :super_admin alias) for tests that need owner-level access.
    trait :owner do
      after(:create) { |u| u.business.update!(owner: u) }
    end

    # Backward-compat alias — many older specs use :super_admin to mean "owner"
    trait :super_admin do
      after(:create) { |u| u.business.update!(owner: u) }
    end

    # Relationship-based manager traits — creates a branch, sets manager relationship,
    # and grants the standard permission set for that role. Tests that need a manager
    # WITHOUT specific permissions should create a plain user and set branch relationships
    # directly, rather than using these traits.
    trait :branch_manager do
      after(:create) do |u|
        branch = Branch.find_or_create_by!(business: u.business, name: "Test Branch #{u.id}") do |b|
          b.active = true
        end
        branch.update_column(:branch_manager_id, u.id)

        role = PermissionRole.find_or_create_by!(business: u.business, name: "Branch Manager #{u.business_id}") do |r|
          r.permissions = %w[view_employees view_attendance manage_attendance
                             view_requests approve_requests
                             assign_shifts view_shifts
                             view_payroll complete_branch_review
                             view_adjustments manage_adjustments approve_adjustments]
        end
        u.update_column(:permission_role_id, role.id)
      end
    end

    trait :area_manager do
      after(:create) do |u|
        branch = Branch.find_or_create_by!(business: u.business, name: "Test Branch #{u.id}") do |b|
          b.active = true
        end
        branch.update_column(:area_manager_id, u.id)

        role = PermissionRole.find_or_create_by!(business: u.business, name: "Area Manager #{u.business_id}") do |r|
          r.permissions = %w[view_employees view_attendance manage_attendance
                             view_requests approve_requests
                             assign_shifts view_shifts
                             view_payroll view_draft_payroll complete_branch_review
                             view_adjustments manage_adjustments approve_adjustments]
        end
        u.update_column(:permission_role_id, role.id)
      end
    end

    trait :accountant do
      after(:create) do |u|
        role = PermissionRole.find_or_create_by!(business: u.business, name: "Finance #{u.business_id}") do |r|
          r.permissions       = %w[view_payroll view_draft_payroll view_payroll_analytics view_payroll_audit_log
                                   create_payroll regenerate_payroll submit_payroll_review
                                   complete_branch_review approve_payroll_items
                                   manage_payroll_overrides manage_payroll_deduction_waivers
                                   finalize_payroll pay_payroll reopen_payroll delete_payroll
                                   view_adjustments manage_adjustments approve_adjustments
                                   view_requests pay_advances]
          r.permission_scopes = {
            "view_payroll"           => "business_wide",
            "view_payroll_analytics" => "business_wide",
            "view_adjustments"       => "business_wide",
            "manage_adjustments"     => "business_wide",
            "approve_adjustments"    => "business_wide",
            "view_requests"          => "business_wide",
            "pay_advances"           => "business_wide"
          }
        end
        u.update_column(:permission_role_id, role.id)
      end
    end

    trait :employee do
      # plain user — no special setup needed
    end

    # Has a phone number in addition to email
    trait :with_phone do
      sequence(:phone_number) { |n| "+966500#{n.to_s.rjust(6, '0')}" }
    end

    # Has only a phone number — no email address
    trait :phone_only do
      email { nil }
      sequence(:phone_number) { |n| "+966500#{n.to_s.rjust(6, '0')}" }
    end

    trait :inactive do
      active { false }
    end

    # Pre-created by admin; employee has not yet set a password
    trait :unregistered do
      password              { nil }
      password_confirmation { nil }
      after(:create) { |u| u.update_column(:encrypted_password, "") }
    end
  end
end
