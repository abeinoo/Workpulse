require "rails_helper"

# The Operations Dashboard is gated by the view_reports permission alone
# (b84dde3 replaced the earlier view_payroll / view_attendance / approve_requests
# gate). Authorization is permission-driven, not role-driven: what matters is
# whether the user's role holds view_reports, never the role's name. Data
# scoping of the dashboard's figures lives in OperationsDashboardController.
RSpec.describe OperationsDashboardPolicy, type: :model do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business) }

  def user_with(permissions, role_name: "Role #{SecureRandom.hex(4)}")
    role = create(:permission_role, business: business, name: role_name, permissions: permissions)
    create(:user, business: business, permission_role: role)
  end

  def index?(user) = described_class.new(user, :operations_dashboard).index?

  describe "index?" do
    it "permits owner" do
      expect(index?(owner)).to be true
    end

    it "permits any user whose role holds view_reports, whatever the role is called" do
      [ "Accountant", "Branch Manager", "Area Manager", "Custom Reporting Role" ].each do |name|
        expect(index?(user_with(%w[view_reports], role_name: name))).to be(true), "#{name} with view_reports"
      end
    end

    it "denies a user without view_reports, even holding the permissions that used to grant access" do
      expect(index?(user_with(%w[view_payroll view_attendance view_requests approve_requests view_dashboard]))).to be false
    end

    it "denies the built-in role traits that do not hold view_reports" do
      %i[accountant branch_manager area_manager].each do |trait|
        user = create(:user, trait, business: business)
        expect(user.can?(:view_reports)).to be(false)
        expect(index?(user)).to be(false), "#{trait} without view_reports"
      end
    end

    it "denies plain employee" do
      expect(index?(employee)).to be false
    end
  end
end
