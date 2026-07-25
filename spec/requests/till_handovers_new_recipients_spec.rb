require "rails_helper"

RSpec.describe "TillHandovers#new — cashier handover recipient list", type: :request do
  let(:business) { create(:business) }
  let(:branch)       { create(:branch, business: business) }
  let(:other_branch) { create(:branch, business: business) }

  def user_with(*perms, scopes: {})
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: scopes
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def assign_shift(user, to_branch)
    create(:shift_assignment, business: business, user: user, branch: to_branch)
  end

  let(:actor) { user_with("view_daily_reconciliation", "close_till_session") }

  before { assign_shift(actor, branch) }

  def get_new
    sign_in actor
    get new_till_handover_path
  end

  it "shows only employees with accept_till_handover for an ordinary branch user" do
    permitted   = user_with("view_daily_reconciliation", "accept_till_handover")
    unpermitted = user_with("view_daily_reconciliation")
    assign_shift(permitted, branch)
    assign_shift(unpermitted, branch)

    get_new

    expect(response.body).to include(permitted.full_name)
    expect(response.body).not_to include(unpermitted.full_name)
  end

  it "shows the 'no one' message for an ordinary user when nobody in the branch holds the permission" do
    unpermitted = user_with("view_daily_reconciliation")
    assign_shift(unpermitted, branch)

    get_new

    expect(Nokogiri::HTML(response.body).text).to include(I18n.t("till_handovers.new.no_colleagues"))
    expect(response.body).not_to include(unpermitted.full_name)
  end

  it "shows every active branch employee for the business owner (Super Admin), regardless of permission" do
    owner_actor = create(:user, :owner, business: business)
    assign_shift(owner_actor, branch)
    unpermitted = user_with("view_daily_reconciliation")
    assign_shift(unpermitted, branch)

    sign_in owner_actor
    get new_till_handover_path

    expect(response.body).to include(unpermitted.full_name)
    expect(Nokogiri::HTML(response.body).text).not_to include(I18n.t("till_handovers.new.no_colleagues"))
  end

  it "shows every active branch employee for a user with business-wide view_daily_reconciliation scope" do
    accountant = user_with("view_daily_reconciliation", "close_till_session",
                            scopes: { "view_daily_reconciliation" => "business" })
    assign_shift(accountant, branch)
    unpermitted = user_with("view_daily_reconciliation")
    assign_shift(unpermitted, branch)

    sign_in accountant
    get new_till_handover_path

    expect(response.body).to include(unpermitted.full_name)
    expect(Nokogiri::HTML(response.body).text).not_to include(I18n.t("till_handovers.new.no_colleagues"))
  end

  it "never shows employees from a different branch, even for the business owner" do
    owner_actor = create(:user, :owner, business: business)
    assign_shift(owner_actor, branch)
    elsewhere = user_with("view_daily_reconciliation")
    assign_shift(elsewhere, other_branch)

    sign_in owner_actor
    get new_till_handover_path

    expect(response.body).not_to include(elsewhere.full_name)
  end

  it "still shows the 'no one' message for the business owner when the branch truly has no other active employees" do
    # A fresh branch — the shared `actor` from the top-level before block is
    # assigned to `branch`, not this one, so it stays genuinely empty.
    empty_branch = create(:branch, business: business)
    owner_actor  = create(:user, :owner, business: business)
    assign_shift(owner_actor, empty_branch)

    sign_in owner_actor
    get new_till_handover_path

    expect(Nokogiri::HTML(response.body).text).to include(I18n.t("till_handovers.new.no_colleagues"))
  end
end
