FactoryBot.define do
  # An attendance requirement history row (R3.2). Follows the given user's
  # business, so a row never crosses businesses; changed_by defaults to that
  # business's own user.
  factory :employee_attendance_requirement do
    user
    business { user.business }
    changed_by { user }
    status { "required" }
    source { "creation" }
    effective_from { Date.new(2026, 1, 1) }

    trait :not_required do
      status { "not_required" }
    end

    trait :hr_change do
      source { "hr_change" }
      reason { "Role changed" }
    end

    trait :backfill_not_reviewed do
      status { "not_reviewed" }
      source { "backfill" }
      effective_date_basis { "hire_date" }
    end
  end
end
