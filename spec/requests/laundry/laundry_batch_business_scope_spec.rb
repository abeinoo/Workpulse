require "rails_helper"

# BUG-034 — a crafted batch request naming another business's towel type or
# operator is refused (the form lists only own ones).
RSpec.describe "POST laundry batch with another business's towel type or operator (BUG-034)", type: :request do
  let(:business)   { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let(:laundry)    { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let(:other)      { create(:business) }

  before { sign_in owner }

  it "is refused and writes nothing" do
    [ { towel_type_id: other.towel_types.create!(name: "Foreign").id },
      { towel_type_id: towel_type.id, operator_id: create(:user, business: other).id } ].each do |ids|
      expect {
        post laundry_laundry_batches_path, params: { laundry_batch: { laundry_branch_id: laundry.id }.merge(ids) }
      }.not_to change(LaundryBatch, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
