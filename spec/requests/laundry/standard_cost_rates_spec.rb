require "rails_helper"

RSpec.describe "Laundry standard cost rates (per towel type, nested under Towel Types)", type: :request do
  let(:business) { create(:business) }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:drying_towel) { business.towel_types.create!(name: "Drying Towel") }
  let(:hot_towel) { business.towel_types.create!(name: "Hot Towel") }
  let(:owner) { create(:user, :owner, business: business) }

  it "sets a new standard cost rate for a towel type and never edits/deletes prior rows" do
    sign_in owner
    post laundry_towel_type_standard_cost_rates_path(drying_towel), params: { laundry_standard_cost_rate: { cost_per_towel: 1.5 } }
    first_rate = LaundryStandardCostRate.last

    post laundry_towel_type_standard_cost_rates_path(drying_towel), params: { laundry_standard_cost_rate: { cost_per_towel: 1.75 } }

    expect(LaundryStandardCostRate.where(towel_type: drying_towel).count).to eq(2)
    expect(first_rate.reload.cost_per_towel).to eq(1.5) # untouched by the second insert
  end

  it "configures each towel type independently" do
    sign_in owner
    post laundry_towel_type_standard_cost_rates_path(drying_towel), params: { laundry_standard_cost_rate: { cost_per_towel: 1.5 } }
    post laundry_towel_type_standard_cost_rates_path(hot_towel), params: { laundry_standard_cost_rate: { cost_per_towel: 0.75 } }

    expect(LaundryStandardCostRate.effective_for(business, towel_type: drying_towel, at: Time.current).cost_per_towel).to eq(1.5)
    expect(LaundryStandardCostRate.effective_for(business, towel_type: hot_towel, at: Time.current).cost_per_towel).to eq(0.75)
  end

  it "does not ask for a towel type selector — the towel type is already known from the route" do
    sign_in owner

    get new_laundry_towel_type_standard_cost_rate_path(drying_towel)

    expect(response.body).not_to include('name="laundry_standard_cost_rate[towel_type_id]"')
    expect(response.body).to include(drying_towel.name)
  end

  %w[en ar].each do |locale|
    it "renders the towel types and standard cost rate pages without missing translations in #{locale}" do
      laundry_branch
      drying_towel
      owner.update!(preferred_locale: locale)
      sign_in owner

      get laundry_towel_types_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Translation missing")

      get new_laundry_towel_type_standard_cost_rate_path(drying_towel)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Translation missing")

      get laundry_reports_branch_consumption_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Translation missing")

      get laundry_reports_cost_summary_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Translation missing")

      expected_dir = locale == "ar" ? 'dir="rtl"' : 'dir="ltr"'
      expect(response.body).to include(expected_dir)
    end
  end
end
