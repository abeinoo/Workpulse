FactoryBot.define do
  factory :salary_payment_hold do
    user
    business { user.business }
    created_by { association :user, business: user.business }
    reason         { "missing_documents" }
    effective_from { Date.new(2026, 10, 1) }
  end
end
