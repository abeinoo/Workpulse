FactoryBot.define do
  # A Holiday Calendar date (R6). Follows the given creator's business.
  factory :holiday do
    association :created_by, factory: :user
    business { created_by.business }
    sequence(:date) { |n| Date.new(2026, 1, 1) + n.days }
    name { "Public holiday" }
    kind { "public" }
  end
end
