require "rails_helper"

RSpec.describe Api::Pagination, type: :controller do
  include Devise::Test::ControllerHelpers

  controller(Api::V1::BaseController) do
    standard_api_contract!

    def always
      records, pagination = paginate(scoped_users)
      render_api_success(records.map(&:id), meta: { pagination: pagination })
    end

    def optional
      records, pagination = paginate_if_requested(scoped_users)
      render_api_success(records.map(&:id), meta: pagination ? { pagination: pagination } : {})
    end

    private

    def scoped_users = User.where(business_id: current_user.business_id).order(:id)
  end

  let(:business) { create(:business) }
  let!(:users)   { create_list(:user, 4, business: business) }
  let(:ids)      { User.where(business_id: business.id).order(:id).pluck(:id) }

  before do
    path = controller.controller_path
    routes.draw do
      get "always",   to: "#{path}#always"
      get "optional", to: "#{path}#optional"
    end
    sign_in users.first
  end

  def body = JSON.parse(response.body)

  it "paginates with defaults" do
    get :always
    expect(body["data"]).to eq(ids)
    expect(body.dig("meta", "pagination")).to eq(
      "page" => 1, "per_page" => 25, "total" => 4, "total_pages" => 1, "next_page" => nil, "previous_page" => nil
    )
  end

  it "returns the requested page with next/previous links" do
    get :always, params: { page: 2, per_page: 1 }
    expect(body["data"]).to eq([ ids[1] ])
    expect(body.dig("meta", "pagination")).to include("page" => 2, "total_pages" => 4, "next_page" => 3, "previous_page" => 1)
  end

  it "points previous_page at the last real page when past the end" do
    get :always, params: { page: 9, per_page: 2 }
    expect(body["data"]).to eq([])
    expect(body.dig("meta", "pagination")).to include("next_page" => nil, "previous_page" => 2)
  end

  it "caps per_page at 100" do
    get :always, params: { per_page: 500 }
    expect(body.dig("meta", "pagination", "per_page")).to eq(100)
  end

  %w[0 -1 abc 1.5].each do |bad|
    it "rejects page=#{bad} with 400 bad_request" do
      get :always, params: { page: bad }
      expect(response.status).to eq(400)
      expect(body.dig("error", "code")).to eq("bad_request")
      expect(body.dig("error", "details", 0, "field")).to eq("page")
    end
  end

  it "leaves a legacy full list untouched unless pagination is requested" do
    get :optional
    expect(body["data"]).to eq(ids)
    expect(body["meta"]).to eq({})

    get :optional, params: { per_page: 2 }
    expect(body["data"]).to eq(ids.first(2))
    expect(body.dig("meta", "pagination", "total")).to eq(4)
  end
end
