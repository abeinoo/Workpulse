require "rails_helper"

# SEC-M2-8 (D-S8-1 / D-S8-2): manage_devices — every punch log of the business;
# view_attendance — its data scope (configured, else own + managed), as
# AttendanceRecordPolicy::Scope; anyone else — nothing.
RSpec.describe BiometricPunchLogPolicy, type: :model do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:emp_a)    { create(:user, business: business) }
  let(:emp_b)    { create(:user, business: business) }

  let!(:log_a)       { create(:biometric_punch_log, business: business, employee: emp_a) }
  let!(:log_b)       { create(:biometric_punch_log, business: business, employee: emp_b) }
  let!(:foreign_log) { create(:biometric_punch_log, business: other, employee: create(:user, business: other)) }

  before do
    create(:shift_assignment, business: business, user: emp_a, branch: branch_a)
    create(:shift_assignment, business: business, user: emp_b, branch: branch_b)
  end

  def user_with(*permissions, scopes: {})
    role = create(:permission_role, business: business, permissions: permissions.map(&:to_s), permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }.reload
  end

  def manager_of_a(scopes: {})
    user_with(:view_attendance, scopes: scopes).tap { |u| branch_a.update_column(:branch_manager_id, u.id) }
  end

  def visible(user) = described_class::Scope.new(user, BiometricPunchLog).resolve

  describe "#index?" do
    it "permits manage_devices, view_attendance and the owner" do
      [ user_with(:manage_devices), user_with(:view_attendance), create(:user, :owner, business: business) ].each do |user|
        expect(described_class.new(user, BiometricPunchLog).index?).to be(true)
      end
    end

    it "refuses the other admin-gate permissions" do
      [ %i[view_employees], %i[view_payroll], %i[manage_evaluation_templates view_performance_dashboard], %i[manage_branches] ]
        .each { |permissions| expect(described_class.new(user_with(*permissions), BiometricPunchLog).index?).to be(false) }
    end
  end

  describe "#show?" do
    it "is false on the class (never evaluates a record predicate on it)" do
      expect(described_class.new(user_with(:manage_devices), BiometricPunchLog).show?).to be(false)
    end

    it "requires the record inside the scope" do
      viewer = manager_of_a(scopes: { "view_attendance" => "branch" })

      expect(described_class.new(viewer, log_a).show?).to be(true)
      expect(described_class.new(viewer, log_b).show?).to be(false)
      expect(described_class.new(user_with(:manage_devices), foreign_log).show?).to be(false)
      expect(described_class.new(user_with(:view_employees), log_a).show?).to be(false)
    end
  end

  describe "Scope" do
    it "manage_devices: every log of the business" do
      expect(visible(user_with(:manage_devices))).to contain_exactly(log_a, log_b)
    end

    it "business-wide view_attendance: every log of the business" do
      expect(visible(user_with(:view_attendance, scopes: { "view_attendance" => "business" }))).to contain_exactly(log_a, log_b)
    end

    it "branch-scoped view_attendance: the managed branch's employees (and the viewer's own)" do
      viewer  = manager_of_a(scopes: { "view_attendance" => "branch" })
      own_log = create(:biometric_punch_log, business: business, employee: viewer)

      expect(visible(viewer)).to contain_exactly(log_a, own_log)
    end

    it "view_attendance with no configured scope: own + managed (hierarchy default)" do
      viewer  = manager_of_a
      own_log = create(:biometric_punch_log, business: business, employee: viewer)

      expect(visible(viewer)).to contain_exactly(log_a, own_log)
    end

    it "nothing for other permissions" do
      expect(visible(user_with(:view_employees))).to be_empty
    end
  end

  describe ".visible_employees" do
    it "matches the log scope's employees" do
      viewer = manager_of_a(scopes: { "view_attendance" => "branch" })

      expect(described_class.visible_employees(viewer)).to include(emp_a, viewer)
      expect(described_class.visible_employees(viewer)).not_to include(emp_b)
      expect(described_class.visible_employees(user_with(:manage_devices))).to include(emp_a, emp_b)
      expect(described_class.visible_employees(user_with(:view_employees))).to be_empty
    end
  end
end
