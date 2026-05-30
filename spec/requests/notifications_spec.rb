require "rails_helper"

RSpec.describe "Notifications (web)", type: :request do
  let(:business) { create(:business) }
  let(:user)     { create(:user, business: business) }

  before { sign_in user }

  describe "GET /notifications" do
    it "renders the index" do
      create(:notification, user: user)
      get notifications_path
      expect(response).to have_http_status(:ok)
    end

    it "filters by category" do
      create(:notification, user: user, category: "payroll")
      create(:notification, user: user, category: "attendance",
             event_type: "attendance_missing_check_out", severity: "warning")
      get notifications_path(category: "attendance")
      expect(response).to have_http_status(:ok)
    end

    it "paginates without error" do
      create_list(:notification, 25, user: user)
      get notifications_path(page: 2)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /notifications/mark_all_read" do
    it "marks all read and redirects (regression: must not 500)" do
      create_list(:notification, 3, user: user, read_at: nil)
      patch mark_all_read_notifications_path
      expect(response).to have_http_status(:found)
      expect(user.notifications.unread.count).to eq(0)
    end
  end

  describe "PATCH /notifications/:id/mark_read" do
    it "marks a single notification read" do
      n = create(:notification, user: user, read_at: nil)
      patch mark_read_notification_path(n)
      expect(response).to have_http_status(:no_content)
      expect(n.reload.read?).to be(true)
    end
  end
end

RSpec.describe "Notification preferences (web)", type: :request do
  let(:user) { create(:user) }

  before { sign_in user }

  it "renders the preferences page" do
    get notification_preferences_path
    expect(response).to have_http_status(:ok)
  end

  it "persists submitted category toggles (unchecked = disabled)" do
    patch notification_preferences_path, params: { categories: { "payroll" => "1", "attendance" => "0" } }
    expect(response).to have_http_status(:found)
    user.reload
    expect(user.notification_enabled?("payroll")).to be(true)
    expect(user.notification_enabled?("attendance")).to be(false)
  end
end
