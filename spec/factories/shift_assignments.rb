FactoryBot.define do
  factory :shift_assignment do
    transient do
      business { create(:business) }
    end

    user           { create(:user,          business: business) }
    shift          { create(:shift,         :fixed_time, business: business) }
    branch         { create(:branch,        business: business) }
    effective_from { 3.months.ago.to_date }
    effective_to   { nil }
  end
end
