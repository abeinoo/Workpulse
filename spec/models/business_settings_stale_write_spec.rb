require "rails_helper"

# Business#settings is ONE serialized column. These pin that a save from a
# stale copy writes only the keys that copy changed, onto the stored hash —
# never putting back other keys, and never changing the warehouse access mode
# unless OrganizationAccess::WarehouseAccessMode is the writer.
RSpec.describe Business, "settings — stale copies and the warehouse access mode" do
  let!(:business) { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }

  def key = Business::WAREHOUSE_ACCESS_FAIL_CLOSED_SETTING

  def stored = Business.find(business.id).settings.to_h

  def switch(fail_closed)
    OrganizationAccess::WarehouseAccessMode.call(business: business.id, actor: User.find(owner.id), fail_closed: fail_closed)
  end

  it "a copy read before the mode switch keeps the new mode when it saves another setting" do
    stale = Business.find(business.id)
    expect(switch(true)).to be_ok

    stale.update!(finance_overdue_days: 12)

    expect(stored).to include(key => true, "finance_overdue_days" => 12)
  end

  it "a copy read before switching back to legacy keeps legacy when it saves" do
    switch(true)
    stale = Business.find(business.id)
    switch(false)

    stale.update!(finance_notify_thresholds: "1,2")

    expect(stored).to include(key => false, "finance_notify_thresholds" => "1,2")
  end

  it "keeps another copy's concurrent change to a different key" do
    first  = Business.find(business.id)
    second = Business.find(business.id)

    first.update!(finance_overdue_days: 7)
    second.update!(attendance_suspicious_duration_hours: 10)

    expect(stored).to include("finance_overdue_days" => 7, "attendance_suspicious_duration_hours" => 10)
  end

  it "the later of two copies wins for the same key (last write, no merge of values)" do
    first  = Business.find(business.id)
    second = Business.find(business.id)

    first.update!(finance_overdue_days: 7)
    second.update!(finance_overdue_days: 9)

    expect(stored["finance_overdue_days"]).to eq(9)
  end

  it "ignores a mode written through the settings attribute, while applying the other keys of that write" do
    business.update!(settings: (business.settings || {}).merge(key => true, "finance_overdue_days" => 5))

    expect(stored).not_to have_key(key)
    expect(stored["finance_overdue_days"]).to eq(5)
    expect(Business.find(business.id).warehouse_access_fail_closed?).to be(false)
  end

  it "ignores an attempt to turn fail-closed off through the settings attribute" do
    switch(true)
    copy = Business.find(business.id)
    copy.update!(settings: copy.settings.merge(key => false))

    expect(stored[key]).to be(true)
  end

  it "ignores removing the mode key through the settings attribute" do
    switch(true)
    copy = Business.find(business.id)
    copy.update!(settings: copy.settings.except(key))

    expect(stored[key]).to be(true)
  end

  it "never creates a business already fail-closed" do
    created = create(:business, settings: { key => true, "finance_overdue_days" => 4 })
    expect(Business.find(created.id).settings.to_h).to eq("finance_overdue_days" => 4)
  end

  it "a save that does not change settings does not write the column at all" do
    stale = Business.find(business.id)
    switch(true)

    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:sql].match?(/\AUPDATE "businesses"/)
    end
    stale.update!(name: "Renamed")
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(statements.size).to eq(1)
    expect(statements.first).not_to include('"settings"')
    expect(stored[key]).to be(true)
  end

  it "the mode service still records exactly one audit entry per switch" do
    switch(true)
    Business.find(business.id).update!(finance_overdue_days: 3)
    expect(AuditLog.where(action: "warehouse_access_mode").count).to eq(1)
  end
end
