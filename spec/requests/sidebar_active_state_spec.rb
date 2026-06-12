require "rails_helper"

RSpec.describe "Sidebar active state", type: :request do
  let(:business)    { create(:business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }
  before { sign_in super_admin }

  it "department field on user form is a select (no free text)" do
    get new_admin_user_path
    expect(response.body).to include('name="user[department_id]"')
    expect(response.body).not_to include('id="department-suggestions"')
    expect(response.body).not_to include('name="user[department]"')
  end

  it "expands the Inventory group and highlights the item on an inventory page" do
    get inventory_root_path
    html = response.body
    # the inventory <details> should carry the open attribute
    expect(html).to match(/<details class="sidebar__group" open>\s*<summary[^>]*>\s*#{Regexp.escape(I18n.t("nav.section_inventory"))}/m)
    expect(html).to include("sidebar__nav-item--sub is-active")
  end

  it "expands the Performance group on a performance page" do
    get performance_root_path
    html = response.body
    expect(html).to match(/<details class="sidebar__group" open>\s*<summary[^>]*>\s*#{Regexp.escape(I18n.t("nav.section_performance"))}/m)
    expect(html).to include("is-active")
  end

  it "works the same under the Arabic locale" do
    get inventory_root_path(locale: :ar)
    expect(response.body).to include('<details class="sidebar__group" open>')
    expect(response.body).to include("sidebar__nav-item--sub is-active")
  end
end
