require "rails_helper"

# Query-count regression guard for the payroll period show page. Each
# employee row renders user_avatar_tag (profile_photo, falling back to
# avatar); without preloading those attachments every row issued its own
# attachment + blob lookups, so the page's query count grew with headcount.
RSpec.describe "Payroll period show — query count scaling", type: :request do
  let(:business) { create(:business) }
  let(:viewer)   { create(:user, :super_admin, business: business) }
  let(:period)   { create(:payroll_period, business: business, status: :under_review) }

  before { sign_in viewer }

  def add_entries(count, with_photo:)
    count.times do
      user = create(:user, business: business)
      if with_photo
        user.profile_photo.attach(io: file_fixture("test_image.png").open,
                                  filename: "photo.png", content_type: "image/png")
      end
      create(:payroll_entry, payroll_period: period, user: user)
    end
  end

  def show_query_count
    get payroll_period_path(period) # warm-up: templates, schema cache
    count_queries { get payroll_period_path(period) }
  end

  it "renders every employee row" do
    add_entries(2, with_photo: true)
    add_entries(1, with_photo: false)

    get payroll_period_path(period)

    expect(response).to have_http_status(:ok)
    period.payroll_entries.includes(:user).each do |entry|
      expect(response.body).to include(ERB::Util.html_escape(entry.user.full_name))
    end
  end

  it "does not issue per-row avatar queries as the employee count grows" do
    add_entries(2, with_photo: true)
    add_entries(1, with_photo: false)
    small = show_query_count

    add_entries(6, with_photo: true)
    add_entries(3, with_photo: false)
    large = show_query_count

    expect(large).to eq(small)
  end
end
