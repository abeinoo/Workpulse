require "rails_helper"

# R6: the Holiday Calendar screens — thin controller over
# Scheduling::HolidayCalendar, manage_holidays only.
RSpec.describe "Holidays", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let(:employee) { create(:user, business: business) }

  context "as a holiday manager" do
    before { sign_in owner }

    it "lists the year's holidays" do
      create(:holiday, created_by: owner, date: Date.new(2026, 7, 23), name: "Revolution Day")
      get holidays_path(year: 2026)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Revolution Day")
    end

    it "adds a holiday through the audited service" do
      expect { post holidays_path, params: { holiday: { date: "2026-10-06", name: "Armed Forces Day", kind: "public" } } }
        .to change(Holiday, :count).by(1).and change { AuditLog.where(action: "holiday.created").count }.by(1)
      expect(response).to redirect_to(holidays_path(year: 2026))
    end

    it "re-renders the form for an invalid holiday" do
      post holidays_path, params: { holiday: { date: "", name: "", kind: "public" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "edits and deletes a holiday" do
      holiday = create(:holiday, created_by: owner, date: Date.new(2026, 7, 23))
      get edit_holiday_path(holiday)
      expect(response).to have_http_status(:ok)

      patch holiday_path(holiday), params: { holiday: { kind: "company" } }
      expect(holiday.reload.kind).to eq("company")

      expect { delete holiday_path(holiday) }.to change(Holiday, :count).by(-1)
      expect(AuditLog.where(action: "holiday.deleted").count).to eq(1)
    end

    it "never reaches another business's holiday" do
      other = create(:holiday, created_by: create(:user, business: create(:business)))
      patch holiday_path(other), params: { holiday: { name: "x" } }
      expect(response).to have_http_status(:not_found)
      expect(other.reload.name).not_to eq("x")
    end
  end

  context "without manage_holidays" do
    before { sign_in employee }

    it "is refused" do
      get holidays_path
      expect(response).to redirect_to(root_path)
      expect { post holidays_path, params: { holiday: { date: "2026-10-06", name: "x", kind: "public" } } }
        .not_to change(Holiday, :count)
    end
  end
end
