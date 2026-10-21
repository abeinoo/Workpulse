require "rails_helper"

# SEC-M2-8 — punch-log authorization (decisions D-S8-1 / D-S8-2). Before the fix
# Admin::BiometricPunchLogsController had no authorization: any holder of one of
# Admin::BaseController's 13 gate permissions saw every punch log of the business
# (employee, punch times, IP address, raw payload). Now BiometricPunchLogPolicy:
# manage_devices — the whole business; view_attendance — its data scope
# (configured, else own + managed); anyone else refused.
RSpec.describe "Security: biometric punch logs authorization (SEC-M2-8)", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }

  let(:branch_a) { create(:branch, business: business, name: "Branch A") }
  let(:branch_b) { create(:branch, business: business, name: "Branch B") }

  let(:emp_a) { create(:user, business: business, first_name: "Alia", last_name: "Inbranch") }
  let(:emp_b) { create(:user, business: business, first_name: "Bassem", last_name: "Otherbranch") }

  let(:device) { create(:biometric_device, business: business, name: "Gate") }

  let!(:log_a)       { create(:biometric_punch_log, business: business, biometric_device: device, employee: emp_a) }
  let!(:log_b)       { create(:biometric_punch_log, business: business, biometric_device: device, employee: emp_b) }
  let!(:foreign_log) { create(:biometric_punch_log, business: other, employee: create(:user, business: other)) }

  before do
    create(:shift_assignment, business: business, user: emp_a, branch: branch_a)
    create(:shift_assignment, business: business, user: emp_b, branch: branch_b)
  end

  def listed_log_paths
    Nokogiri::HTML(response.body).css("a").filter_map { |a| a["href"] if a["href"]&.match?(%r{/admin/biometric_punch_logs/\d+\z}) }
  end

  def path(log) = admin_biometric_punch_log_path(log)

  # A branch manager of branch A (the managed branch drives the "branch" scope and
  # the hierarchy default).
  def manager_of_a(**options)
    api_user_with(business, *options.fetch(:permissions, [ :view_attendance ]), scopes: options.fetch(:scopes, {})).tap do |user|
      branch_a.update_column(:branch_manager_id, user.id)
    end
  end

  describe "refused (an admin-gate permission without manage_devices or view_attendance)" do
    {
      "view_employees"              => %i[view_employees],
      "view_payroll"                => %i[view_payroll],
      "manage_evaluation_templates" => %i[manage_evaluation_templates view_performance_dashboard],
      "manage_branches"             => %i[manage_branches]
    }.each do |label, permissions|
      it "refuses #{label}: index and show redirect with the not-authorized alert" do
        sign_in api_user_with(business, *permissions)

        get admin_biometric_punch_logs_path
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))

        get path(log_a)
        expect(response).to redirect_to(root_path)
      end
    end

    it "keeps redirecting a user without any admin-gate permission" do
      sign_in api_user_with(business, :view_requests)

      get admin_biometric_punch_logs_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "manage_devices: every log of the business" do
    before { sign_in api_user_with(business, :manage_devices) }

    it "lists and shows every log of the business, and every active employee in the filter" do
      get admin_biometric_punch_logs_path

      expect(response).to have_http_status(:ok)
      expect(listed_log_paths).to contain_exactly(path(log_a), path(log_b))
      expect(response.body).to include("Alia Inbranch", "Bassem Otherbranch")

      get path(log_b)
      expect(response).to have_http_status(:ok)
    end

    it "returns 404 for another business's log" do
      get path(foreign_log)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "lets the owner see every log of the business" do
    sign_in create(:user, :owner, business: business)

    get admin_biometric_punch_logs_path
    expect(listed_log_paths).to contain_exactly(path(log_a), path(log_b))
  end

  it "returns 404 to the owner for another business's log" do
    sign_in create(:user, :owner, business: business)

    get path(foreign_log)
    expect(response).to have_http_status(:not_found)
  end

  it "business-wide view_attendance sees every log of the business" do
    sign_in api_user_with(business, :view_attendance, scopes: { "view_attendance" => "business" })

    get admin_biometric_punch_logs_path
    expect(listed_log_paths).to contain_exactly(path(log_a), path(log_b))

    get path(log_b)
    expect(response).to have_http_status(:ok)
  end

  describe "branch-scoped view_attendance (manages branch A)" do
    let!(:viewer) { manager_of_a(scopes: { "view_attendance" => "branch" }) }

    before { sign_in viewer }

    it "lists only branch A's logs, and only branch A's employees in the filter" do
      get admin_biometric_punch_logs_path

      expect(response).to have_http_status(:ok)
      expect(listed_log_paths).to eq([ path(log_a) ])
      expect(response.body).to include("Alia Inbranch")
      expect(response.body).not_to include("Bassem Otherbranch")
    end

    # Requests that end in a rescued 404 are kept one per example.
    it "returns 404 for another branch's log" do
      get path(log_b)
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for another business's log" do
      get path(foreign_log)
      expect(response).to have_http_status(:not_found)
    end

    it "ignores an out-of-scope employee filter (reveals neither the employee nor the records)" do
      get admin_biometric_punch_logs_path, params: { employee_id: emp_b.id }

      expect(listed_log_paths).to eq([ path(log_a) ])
      expect(response.body).not_to include("Bassem Otherbranch")
    end

    it "shows nothing from another branch when that branch is selected" do
      get admin_biometric_punch_logs_path, params: { branch_id: branch_b.id }

      expect(listed_log_paths).to be_empty
      expect(response.body).not_to include("Bassem Otherbranch")
    end
  end

  describe "view_attendance without a configured scope (the hierarchy default: own + managed)" do
    let!(:viewer) { manager_of_a }
    let!(:own_log) { create(:biometric_punch_log, business: business, biometric_device: device, employee: viewer) }

    before { sign_in viewer }

    it "lists the viewer's own logs and branch A's, not branch B's" do
      get admin_biometric_punch_logs_path

      expect(listed_log_paths).to contain_exactly(path(own_log), path(log_a))
    end

    it "returns 404 for branch B's log" do
      get path(log_b)
      expect(response).to have_http_status(:not_found)
    end
  end
end
