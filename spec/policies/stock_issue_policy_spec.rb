require "rails_helper"

# One permission per Stock Issue operation (Inventory::StockIssueAuthorization),
# never derived from a job title; manage_inventory still honoured during the
# additive transition; manage_stock_issues grants nothing any more.
RSpec.describe StockIssuePolicy, type: :policy do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  let(:creator)   { stock_issue_user(business, :create_stock_issues) }
  let(:approver)  { stock_issue_user(business, :approve_stock_issues) }
  let(:confirmer) { stock_issue_user(business, :confirm_stock_issues) }
  let(:canceller) { stock_issue_user(business, :cancel_stock_issues) }
  let(:voider)    { stock_issue_user(business, :void_stock_issues) }
  let(:viewer)    { stock_issue_user(business) } # view_inventory + view_stock_issues only

  def user_with(*permissions)
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions.map(&:to_s))
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def build_issue(status: "draft")
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
    i.items.build(product: product, quantity: 1) unless status == "draft"
    save_stock_issue_in_status!(i, status).reload
  end

  describe "#index? / #show? — view_stock_issues, independent of view_inventory" do
    it "requires view_stock_issues" do
      expect(described_class.new(viewer, StockIssue).index?).to be true
      expect(described_class.new(user_with(:view_stock_issues), StockIssue).index?).to be true
    end

    it "is not granted by view_inventory alone" do
      expect(described_class.new(user_with(:view_inventory), StockIssue).index?).to be false
      expect(described_class.new(user_with(:view_inventory), build_issue).show?).to be false
    end
  end

  describe "#update? / #destroy? / #submit? — create_stock_issues" do
    it "allows the create permission to edit/submit/delete a draft" do
      policy = described_class.new(creator, build_issue(status: "draft"))
      expect(policy.update?).to be true
      expect(policy.destroy?).to be true
      expect(policy.submit?).to be true
    end

    it "allows editing a pending or approved issue (Edit Request) but not deleting or submitting it" do
      %w[pending_approval approved].each do |status|
        policy = described_class.new(creator, build_issue(status: status))
        expect(policy.update?).to be(true), status
        expect(policy.destroy?).to be(false), status
        expect(policy.submit?).to be(false), status
      end
    end

    it "blocks editing once issued, rejected, or cancelled" do
      %w[issued rejected cancelled].each do |status|
        expect(described_class.new(creator, build_issue(status: status)).update?).to be(false), status
      end
    end

    it "is refused to every other permission" do
      issue = build_issue(status: "draft")
      [ approver, confirmer, canceller, voider, viewer ].each do |user|
        expect(described_class.new(user, issue).update?).to be(false)
        expect(described_class.new(user, issue).destroy?).to be(false)
      end
    end
  end

  describe "#approve? / #reject? — approve_stock_issues" do
    it "requires approve_stock_issues and pending_approval status" do
      issue = build_issue(status: "pending_approval")
      expect(described_class.new(approver, issue).approve?).to be true
      expect(described_class.new(approver, issue).reject?).to be true
      [ creator, confirmer, canceller, voider, viewer ].each do |user|
        expect(described_class.new(user, issue).approve?).to be(false)
      end
      expect(described_class.new(approver, build_issue(status: "approved")).approve?).to be false
    end
  end

  describe "#confirm? — confirm_stock_issues" do
    it "requires confirm_stock_issues and approved status" do
      issue = build_issue(status: "approved")
      expect(described_class.new(confirmer, issue).confirm?).to be true
      expect(described_class.new(approver, issue).confirm?).to be false
      expect(described_class.new(confirmer, build_issue(status: "pending_approval")).confirm?).to be false
    end

    it "lets one person hold both approve and confirm" do
      both = stock_issue_user(business, :approve_stock_issues, :confirm_stock_issues)
      expect(described_class.new(both, build_issue(status: "approved")).confirm?).to be true
    end
  end

  describe "#cancel? — cancel_stock_issues, unposted only" do
    it "allows cancelling a draft or approved issue" do
      expect(described_class.new(canceller, build_issue(status: "draft")).cancel?).to be true
      expect(described_class.new(canceller, build_issue(status: "approved")).cancel?).to be true
    end

    it "refuses once issued, and while pending approval" do
      expect(described_class.new(canceller, build_issue(status: "issued")).cancel?).to be false
      expect(described_class.new(canceller, build_issue(status: "pending_approval")).cancel?).to be false
    end

    it "is no longer granted by the create permission" do
      expect(described_class.new(creator, build_issue(status: "approved")).cancel?).to be false
    end
  end

  describe "#void? — void_stock_issues, posted only" do
    it "is only true once issued" do
      expect(described_class.new(voider, build_issue(status: "issued")).void?).to be true
      expect(described_class.new(voider, build_issue(status: "approved")).void?).to be false
      expect(described_class.new(voider, build_issue(status: "draft")).void?).to be false
    end

    it "is not granted by create or cancel" do
      issued = build_issue(status: "issued")
      expect(described_class.new(creator, issued).void?).to be false
      expect(described_class.new(canceller, issued).void?).to be false
    end
  end

  describe "#quick_issue? — quick_issue_stock + the company setting" do
    let!(:owner) { create(:user, :owner, business: business) }

    def disable_quick_issue!
      expect(OrganizationAccess::StockIssueWorkflowSettings.call(business: business, actor: owner,
                                                                 self_approval: "forbidden",
                                                                 quick_issue_enabled: false)).to be_ok
      business.reload
    end

    it "requires quick_issue_stock — independent of the standard permissions" do
      expect(described_class.new(user_with(:view_inventory, :quick_issue_stock), StockIssue).quick_issue?).to be true
    end

    it "is never derived from create + approve + confirm" do
      full = stock_issue_user(business, :create_stock_issues, :approve_stock_issues, :confirm_stock_issues)
      expect(described_class.new(full, StockIssue).quick_issue?).to be false
    end

    it "is refused to everyone but the owner while the company setting is disabled" do
      quick = user_with(:view_inventory, :quick_issue_stock)
      disable_quick_issue!
      expect(described_class.new(quick.reload, StockIssue).quick_issue?).to be false
      expect(described_class.new(owner.reload, StockIssue).quick_issue?).to be true
    end
  end

  describe "legacy and transitional keys" do
    it "manage_stock_issues grants nothing any more" do
      legacy = user_with(:view_inventory, :manage_stock_issues)
      issue  = build_issue(status: "draft")
      expect(described_class.new(legacy, StockIssue).create?).to be false
      expect(described_class.new(legacy, issue).update?).to be false
      expect(described_class.new(legacy, StockIssue).quick_issue?).to be false
    end

    it "manage_inventory keeps every Stock Issue operation during the transition" do
      umbrella = user_with(:view_inventory, :manage_inventory)
      expect(described_class.new(umbrella, StockIssue).index?).to be true
      expect(described_class.new(umbrella, StockIssue).create?).to be true
      expect(described_class.new(umbrella, build_issue(status: "pending_approval")).approve?).to be true
      expect(described_class.new(umbrella, build_issue(status: "approved")).confirm?).to be true
      expect(described_class.new(umbrella, build_issue(status: "approved")).cancel?).to be true
      expect(described_class.new(umbrella, build_issue(status: "issued")).void?).to be true
      expect(described_class.new(umbrella, StockIssue).quick_issue?).to be true
    end

    it "the owner holds every operation" do
      owner = create(:user, :owner, business: business)
      %i[index? create?].each { |action| expect(described_class.new(owner, StockIssue).public_send(action)).to be true }
      expect(described_class.new(owner, build_issue(status: "issued")).void?).to be true
    end
  end
end
