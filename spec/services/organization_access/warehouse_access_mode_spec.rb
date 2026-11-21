require "rails_helper"

# OrganizationAccess::WarehouseAccessMode — the one, audited, owner-only writer
# of Business#warehouse_access_fail_closed? (gradual fail-closed activation).
RSpec.describe OrganizationAccess::WarehouseAccessMode do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)       { create(:user, :owner, business: business) }
  let!(:other_owner) { create(:user, :owner, business: other) }

  def switch(fail_closed:, actor: owner, target: business, reason: nil)
    described_class.call(business: target, actor: actor, fail_closed: fail_closed, reason: reason)
  end

  def mode_audits = AuditLog.where(action: "warehouse_access_mode")

  def setting(target) = target.reload.settings.to_h["warehouse_access_fail_closed"]

  it "switches the owner's business to fail-closed and audits the previous and new mode" do
    result = switch(fail_closed: true, reason: "access review done")

    expect(result).to be_ok
    expect(business.reload.warehouse_access_fail_closed?).to be(true)
    expect(setting(business)).to be(true)

    audit = mode_audits.sole
    expect(audit.auditable).to eq(business)
    expect(audit.actor_id).to eq(owner.id)
    expect(audit.business_id).to eq(business.id)
    expect(audit.changes_json).to eq("warehouse_access_fail_closed" => [ false, true ])
    expect(audit.metadata).to include("previous_mode" => "legacy", "new_mode" => "fail_closed", "reason" => "access review done")
  end

  it "switches back to legacy with its own audit entry" do
    switch(fail_closed: true)
    result = switch(fail_closed: false)

    expect(result).to be_ok
    expect(business.reload.warehouse_access_fail_closed?).to be(false)
    expect(mode_audits.order(:id).last.metadata).to include("previous_mode" => "fail_closed", "new_mode" => "legacy")
  end

  it "changes nothing and writes no audit entry when the mode is already the requested one" do
    result = switch(fail_closed: false)
    expect(result.error).to eq(:unchanged)
    expect(mode_audits).to be_empty
  end

  it "keeps every other settings key" do
    business.update!(finance_overdue_days: 9, finance_notify_thresholds: "2,5")
    switch(fail_closed: true)

    business.reload
    expect(business.finance_overdue_days).to eq(9)
    expect(business.finance_notify_thresholds).to eq([ 2, 5 ])
  end

  it "touches only the requested business" do
    switch(fail_closed: true)
    expect(other.reload.warehouse_access_fail_closed?).to be(false)
    expect(setting(other)).to be_nil
  end

  describe "authorization and business scope" do
    it "refuses another business's owner" do
      expect(switch(fail_closed: true, actor: other_owner).error).to eq(:not_authorized)
      expect(business.reload.warehouse_access_fail_closed?).to be(false)
      expect(mode_audits).to be_empty
    end

    it "refuses a non-owner even with settings, inventory and company-wide warehouse permissions" do
      admin = user_with_stock_permissions(business, :manage_settings, :view_inventory, :manage_inventory, :access_all_warehouses)
      expect(switch(fail_closed: true, actor: admin).error).to eq(:not_authorized)
      expect(business.reload.warehouse_access_fail_closed?).to be(false)
    end

    it "refuses an inactive owner" do
      owner.update_column(:active, false)
      expect(switch(fail_closed: true, actor: owner.reload).error).to eq(:not_authorized)
    end

    it "refuses a missing actor or an unknown business" do
      expect(switch(fail_closed: true, actor: nil).error).to eq(:not_authorized)
      expect(switch(fail_closed: true, target: Business.maximum(:id).to_i + 1).error).to eq(:not_authorized)
    end

    [ "true", 1, nil, "fail_closed" ].each do |invalid|
      it "refuses a non-boolean mode (#{invalid.inspect})" do
        expect(switch(fail_closed: invalid).error).to eq(:invalid_mode)
        expect(setting(business)).to be_nil
      end
    end
  end

  it "rolls the setting back when the audit entry cannot be written" do
    fail_audit_writes!(:warehouse_access_mode)

    result = switch(fail_closed: true)

    expect(result.error).to eq(:failed)
    expect(business.reload.warehouse_access_fail_closed?).to be(false)
    expect(setting(business)).to be_nil
  end
end
