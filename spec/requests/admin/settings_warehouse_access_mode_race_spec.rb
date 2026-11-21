require "rails_helper"

# The admin Settings form (Admin::SettingsController#update — the one
# controller path that writes Business#settings) must never undo a warehouse
# access mode switch that committed while the request was running, and must
# keep the other settings keys. The switch is injected between the request's
# load of the business and its save.
RSpec.describe "Admin settings vs the warehouse access mode switch", type: :request do
  let!(:business) { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let(:admin) do
    role = business.permission_roles.create!(name: "Settings admin", permissions: %w[manage_settings])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def stored = Business.find(business.id).settings.to_h

  def switch_during_settings_save(fail_closed)
    switched = false
    allow_any_instance_of(Business).to receive(:update).and_wrap_original do |original, *args, **kwargs|
      unless switched
        switched = true
        result = OrganizationAccess::WarehouseAccessMode.call(business: business.id, actor: User.find(owner.id),
                                                               fail_closed: fail_closed)
        raise "switch failed: #{result.error}" unless result.ok?
      end
      original.call(*args, **kwargs)
    end
  end

  def submit_settings(overdue_days)
    patch admin_settings_path, params: { business: { finance_overdue_days: overdue_days } }
  end

  it "keeps a switch to fail-closed that committed during the settings request, and saves the form" do
    sign_in admin
    switch_during_settings_save(true)

    submit_settings(11)

    expect(response).to redirect_to(admin_settings_path)
    expect(stored).to include("warehouse_access_fail_closed" => true, "finance_overdue_days" => 11)
    expect(AuditLog.where(action: "warehouse_access_mode").count).to eq(1)
  end

  it "keeps a switch back to legacy that committed during the settings request" do
    OrganizationAccess::WarehouseAccessMode.call(business: business.id, actor: owner, fail_closed: true)
    sign_in admin
    switch_during_settings_save(false)

    submit_settings(6)

    expect(stored).to include("warehouse_access_fail_closed" => false, "finance_overdue_days" => 6)
  end

  it "a crafted settings parameter cannot set the mode (not a permitted attribute)" do
    sign_in admin
    patch admin_settings_path, params: { business: { finance_overdue_days: 4, settings: { warehouse_access_fail_closed: true },
                                                     warehouse_access_fail_closed: true } }

    expect(stored).not_to have_key("warehouse_access_fail_closed")
    expect(stored["finance_overdue_days"]).to eq(4)
  end

  it "keeps unrelated keys written by another save during the request" do
    sign_in admin
    allow_any_instance_of(Business).to receive(:update).and_wrap_original do |original, *args, **kwargs|
      Business.find(business.id).update!(finance_notify_thresholds: "4,8")
      original.call(*args, **kwargs)
    end

    submit_settings(13)

    expect(stored).to include("finance_notify_thresholds" => "4,8", "finance_overdue_days" => 13)
  end
end
