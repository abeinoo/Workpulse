require "rails_helper"

# POST /api/v1/auth/login rate limits (Api::V1::SessionsController).
# The test env uses a null cache store (no limits); swap in a real store here.
RSpec.describe "API v1 rate limiting — login", type: :request do
  let(:business) { create(:business) }
  let!(:user)    { create(:user, business: business, email: "limit@example.com") }

  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  def attempt(login, password = "wrong", ip: "10.0.0.1")
    post "/api/v1/auth/login", params: { login: login, password: password }, as: :json,
                               headers: { "REMOTE_ADDR" => ip }
  end

  it "allows 10 attempts per login identifier per IP, then answers 429 in the standard envelope" do
    10.times { attempt("limit@example.com") }
    expect(response).to have_http_status(:unauthorized)

    attempt("limit@example.com")
    expect_standard_error(:too_many_requests, code: "rate_limited")
    expect(response.headers["Retry-After"]).to eq(5.minutes.to_i.to_s)
  end

  it "blocks even the correct password once limited" do
    11.times { attempt("limit@example.com") }
    attempt("limit@example.com", "password123")
    expect(response).to have_http_status(:too_many_requests)
  end

  it "counts identifiers independently (a shared salon IP is not locked out by one user)" do
    11.times { attempt("limit@example.com") }
    attempt("someone-else@example.com")
    expect(response).to have_http_status(:unauthorized)
  end

  it "counts the same identifier independently per IP" do
    11.times { attempt("limit@example.com", ip: "10.0.0.1") }
    attempt("limit@example.com", "password123", ip: "10.0.0.2")
    expect(response).to have_http_status(:ok)
  end

  it "caps total attempts per IP at 60 per minute" do
    60.times { |i| attempt("user#{i}@example.com") }
    attempt("fresh@example.com")
    expect(response).to have_http_status(:too_many_requests)
  end

  it "does not store the raw login identifier in cache keys" do
    attempt("limit@example.com")
    keys = Rails.cache.instance_variable_get(:@data).keys
    expect(keys.join).not_to include("limit@example.com")
  end

  it "is not applied when the cache store is null (test/default behaviour)" do
    Rails.cache = ActiveSupport::Cache::NullStore.new
    15.times { attempt("limit@example.com") }
    expect(response).to have_http_status(:unauthorized)
  end
end
