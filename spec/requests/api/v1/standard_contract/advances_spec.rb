require "rails_helper"

# GET /api/v1/advances — pilot endpoint on the standard contract.
# The legacy-compatible parts are also covered by
# spec/requests/api/v1/characterization/self_service_spec.rb.
RSpec.describe "API v1 standard contract — advances", type: :request do
  let(:business) { create(:business) }
  let(:viewer)   { api_user_with(business, :view_payroll) }
  let(:employee) { create(:user, business: business) }

  let!(:older)   { create(:advance, business: business, user: employee, issued_at: 3.days.ago, total_amount: 300, remaining_amount: 300) }
  let!(:middle)  { create(:advance, business: business, user: employee, issued_at: 2.days.ago, total_amount: 900, remaining_amount: 0, status: :fully_repaid) }
  let!(:newest)  { create(:advance, business: business, user: employee, issued_at: 1.day.ago,  total_amount: 600, remaining_amount: 600) }
  let!(:foreign) { create(:advance) }

  let(:advance_keys) { %w[id user_id total_amount remaining_amount status issued_at repaid_amount] }

  before { sign_in viewer }

  def ids = api_data.map { |a| a["id"] }

  describe "index" do
    it "keeps the legacy fields and full-list default, adding meta and request_id" do
      get "/api/v1/advances", as: :json
      expect_standard_success
      expect(ids).to eq([ newest.id, middle.id, older.id ])
      expect(api_data.first.keys).to match_array(advance_keys)
      expect(api_json["meta"]).to eq({})
    end

    it "serializes exactly what the legacy advance_json produced" do
      get "/api/v1/advances", as: :json
      # The legacy helper ran inside the request, i.e. in the business timezone.
      legacy = Time.use_zone(business.timezone_object) do
        newest.reload.slice(:id, :user_id, :total_amount, :remaining_amount, :status, :issued_at)
              .merge(repaid_amount: newest.repaid_amount).to_json
      end
      expect(api_data.first).to eq(JSON.parse(legacy))
    end

    it "never includes another business's advances" do
      get "/api/v1/advances", params: { per_page: 100 }, as: :json
      expect(ids).not_to include(foreign.id)
    end

    it "paginates when page/per_page are sent" do
      get "/api/v1/advances", params: { page: 2, per_page: 2 }, as: :json
      expect_standard_success
      expect(ids).to eq([ older.id ])
      expect(api_json.dig("meta", "pagination")).to eq(
        "page" => 2, "per_page" => 2, "total" => 3, "total_pages" => 2, "next_page" => nil, "previous_page" => 1
      )
    end

    it "caps per_page at 100" do
      get "/api/v1/advances", params: { per_page: 1000 }, as: :json
      expect(api_json.dig("meta", "pagination", "per_page")).to eq(100)
    end

    it "returns 400 bad_request for malformed pagination" do
      get "/api/v1/advances", params: { page: 0 }, as: :json
      expect_standard_error(:bad_request, code: "bad_request")
      expect(api_json.dig("error", "details", 0, "field")).to eq("page")
    end

    it "filters by an allowlisted enum" do
      get "/api/v1/advances", params: { filter: { status: "fully_repaid" } }, as: :json
      expect(ids).to eq([ middle.id ])
    end

    it "rejects an unknown filter (e.g. user_id) with 400" do
      get "/api/v1/advances", params: { filter: { user_id: employee.id } }, as: :json
      expect_standard_error(:bad_request, code: "bad_request")
      expect(api_json.dig("error", "details", 0, "code")).to eq("unknown_filter")
    end

    it "sorts by an allowlisted field" do
      get "/api/v1/advances", params: { sort: "total_amount" }, as: :json
      expect(ids).to eq([ older.id, newest.id, middle.id ])
    end

    it "rejects an unknown sort with 400" do
      get "/api/v1/advances", params: { sort: "user_id" }, as: :json
      expect_standard_error(:bad_request, code: "bad_request")
    end

    it "rejects search (not supported on this endpoint) with 400" do
      get "/api/v1/advances", params: { q: "x" }, as: :json
      expect_standard_error(:bad_request, code: "bad_request")
    end

    it "scopes a plain employee to their own advances" do
      sign_in employee
      create(:advance, business: business)
      get "/api/v1/advances", as: :json
      expect(ids).to match_array([ older.id, middle.id, newest.id ])
    end
  end

  describe "show" do
    it "returns one advance in the standard envelope" do
      get "/api/v1/advances/#{newest.id}", as: :json
      expect_standard_success
      expect(api_data.keys).to match_array(advance_keys)
    end

    it "returns the standard 404 for another business's advance (keeping legacy keys)" do
      get "/api/v1/advances/#{foreign.id}", as: :json
      expect_standard_error(:not_found, code: "not_found")
      expect(api_json["message"]).to eq("Record not found")
      expect(api_json["errors"]).to eq([])
    end
  end

  it "answers unauthenticated requests with the standard 401" do
    sign_out viewer
    get "/api/v1/advances", as: :json
    expect_standard_error(:unauthorized, code: "unauthenticated")
  end
end
