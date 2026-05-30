require "rails_helper"

RSpec.describe "API V1 Notifications", type: :request do
  let(:business) { create(:business) }
  let(:user)     { create(:user, business: business) }
  let(:other)    { create(:user, business: business) }

  # ── Index ───────────────────────────────────────────────────────────────────
  describe "GET /api/v1/notifications" do
    before { sign_in user }

    let!(:mine)    { create(:notification, user: user, category: "payroll") }
    let!(:foreign) { create(:notification, user: other, category: "payroll") }

    it "returns only the current user's notifications with meta" do
      get "/api/v1/notifications", as: :json
      expect(response).to have_http_status(:ok)

      body = response.parsed_body
      ids  = body["data"]["notifications"].map { |n| n["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(foreign.id)
      expect(body["data"]["meta"]).to include("page", "per_page", "total", "total_pages", "unread_count")
    end

    it "filters by category" do
      create(:notification, user: user, category: "attendance",
             event_type: "attendance_missing_check_out", severity: "warning")
      get "/api/v1/notifications", params: { category: "attendance" }, as: :json

      cats = response.parsed_body["data"]["notifications"].map { |n| n["category"] }
      expect(cats).to all(eq("attendance"))
    end

    it "filters by unread" do
      create(:notification, :read, user: user)
      get "/api/v1/notifications", params: { unread: "1" }, as: :json

      reads = response.parsed_body["data"]["notifications"].map { |n| n["read"] }
      expect(reads).to all(be(false))
    end

    it "paginates" do
      create_list(:notification, 25, user: user)
      get "/api/v1/notifications", params: { page: 2 }, as: :json
      meta = response.parsed_body["data"]["meta"]
      expect(meta["page"]).to eq(2)
      expect(meta["total"]).to be >= 26
    end
  end

  # ── Unread count ──────────────────────────────────────────────────────────────
  describe "GET /api/v1/notifications/unread_count" do
    before { sign_in user }

    it "returns the unread count for the current user only" do
      create_list(:notification, 3, user: user, read_at: nil)
      create(:notification, :read, user: user)
      create(:notification, user: other, read_at: nil)

      get "/api/v1/notifications/unread_count", as: :json
      expect(response.parsed_body["data"]["unread_count"]).to eq(3)
    end
  end

  # ── Mark read ─────────────────────────────────────────────────────────────────
  describe "PATCH /api/v1/notifications/:id/mark_read" do
    before { sign_in user }

    it "marks the notification read" do
      n = create(:notification, user: user, read_at: nil)
      patch "/api/v1/notifications/#{n.id}/mark_read", as: :json
      expect(response).to have_http_status(:ok)
      expect(n.reload.read?).to be(true)
    end

    it "does not allow marking another user's notification (404)" do
      n = create(:notification, user: other, read_at: nil)
      patch "/api/v1/notifications/#{n.id}/mark_read", as: :json
      expect(response).to have_http_status(:not_found)
      expect(n.reload.read?).to be(false)
    end
  end

  # ── Mark all read ─────────────────────────────────────────────────────────────
  describe "PATCH /api/v1/notifications/mark_all_read" do
    before { sign_in user }

    it "marks all of the current user's notifications read" do
      create_list(:notification, 3, user: user, read_at: nil)
      patch "/api/v1/notifications/mark_all_read", as: :json
      expect(response).to have_http_status(:ok)
      expect(user.notifications.unread.count).to eq(0)
    end

    it "leaves other users' notifications untouched" do
      foreign = create(:notification, user: other, read_at: nil)
      create(:notification, user: user, read_at: nil)
      patch "/api/v1/notifications/mark_all_read", as: :json
      expect(foreign.reload.read?).to be(false)
    end
  end

  # ── Auth ──────────────────────────────────────────────────────────────────────
  describe "authentication" do
    it "rejects unauthenticated requests" do
      get "/api/v1/notifications", as: :json
      expect(response.status).to be_in([ 401, 302 ])
    end
  end
end
