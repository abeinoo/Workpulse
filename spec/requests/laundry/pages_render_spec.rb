require "rails_helper"

RSpec.describe "Laundry pages render without error, in English and Arabic (RTL)", type: :request do
  let(:business) { create(:business) }
  let!(:sales_branch)   { create(:branch, business: business, branch_type: "sales") }
  let!(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let!(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let!(:warehouse)  { business.warehouses.create!(name: "Laundry Warehouse") }
  let(:owner) { create(:user, :owner, business: business) }

  let!(:transfer) do
    business.towel_transfers.create!(towel_type: towel_type, source_branch: sales_branch,
                                     destination_branch: laundry_branch, towel_status: "dirty",
                                     declared_quantity: 10)
  end
  let!(:batch) do
    business.laundry_batches.create!(laundry_branch: laundry_branch, towel_type: towel_type,
                                     batch_number: "LB-000001")
  end

  %w[en ar].each do |locale|
    context "locale=#{locale}" do
      before do
        owner.update!(preferred_locale: locale)
        sign_in owner
      end

      it "renders every laundry page with a 200 and the expected dir attribute" do
        expected_dir = locale == "ar" ? 'dir="rtl"' : 'dir="ltr"'

        get laundry_root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(expected_dir)

        get laundry_towel_balances_path
        expect(response).to have_http_status(:ok)

        get laundry_towel_types_path
        expect(response).to have_http_status(:ok)
        get new_laundry_towel_type_path
        expect(response).to have_http_status(:ok)
        get new_laundry_towel_type_standard_cost_rate_path(towel_type)
        expect(response).to have_http_status(:ok)

        get laundry_towel_transfers_path
        expect(response).to have_http_status(:ok)
        get new_laundry_towel_transfer_path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('name="towel_transfer[loss_quantity]"')
        expect(response.body).not_to include('name="towel_transfer[loss_reason]"')
        expect(response.body).not_to include('name="towel_transfer[towel_status]"')
        get laundry_towel_transfer_path(transfer)
        expect(response).to have_http_status(:ok)

        get laundry_laundry_batches_path
        expect(response).to have_http_status(:ok)
        get new_laundry_laundry_batch_path
        expect(response).to have_http_status(:ok)
        get laundry_laundry_batch_path(batch)
        expect(response).to have_http_status(:ok)

        get laundry_towel_adjustments_path
        expect(response).to have_http_status(:ok)
        get new_laundry_towel_adjustment_path
        expect(response).to have_http_status(:ok)
      end
    end
  end

  it "renders the in-progress batch show page with the consumption form and completion form" do
    sign_in owner
    Laundry::LaundryBatchService.new(batch).start(actor: owner, input_quantity: 10)

    get laundry_laundry_batch_path(batch)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("laundry.batches.section_consumption"))
    expect(response.body).to include(I18n.t("laundry.batches.section_complete"))
  end

  it "shows each towel type's own current standard washing cost on the Towel Types index" do
    other_towel_type = business.towel_types.create!(name: "Hand Towel")
    business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.5, effective_from: 1.day.ago)
    business.laundry_standard_cost_rates.create!(towel_type: other_towel_type, cost_per_towel: 0.75, effective_from: 1.day.ago)
    sign_in owner

    get laundry_towel_types_path

    expect(response.body).to include(I18n.t("laundry.towel_types.current_cost"))
    expect(response.body).to include(I18n.t("laundry.towel_types.update_cost"))
    expect(response.body).to include("1.50")
    expect(response.body).to include("0.75")
  end

  it "renders the transfer show page's receive form while dispatched" do
    sign_in owner
    Laundry::TowelAdjuster.new(actor: owner).call(towel_type: towel_type, branch: sales_branch, status: "clean",
                                                  adjustment_quantity: 10, reason: "test setup")
    Laundry::TowelTransferCreator.new(transfer).dispatch(actor: owner)

    get laundry_towel_transfer_path(transfer)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("laundry.towel_transfers.actions.receive"))
  end
end
