require "rails_helper"

RSpec.describe "Admin::BiometricPunchLogs", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }

  let(:branch_a) { create(:branch, business: business, name: "Branch A") }
  let(:branch_b) { create(:branch, business: business, name: "Branch B") }

  let(:employee_a) { create(:user, business: business, first_name: "Ahmed", last_name: "Mohamed") }
  let(:employee_b) { create(:user, business: business, first_name: "Sara", last_name: "Ali") }

  let(:device_a) { create(:biometric_device, business: business, name: "Device A") }
  let(:device_b) { create(:biometric_device, business: business, name: "Device B") }

  before do
    create(:shift_assignment, business: business, user: employee_a, branch: branch_a)
    create(:shift_assignment, business: business, user: employee_b, branch: branch_b)
    sign_in owner
  end

  let!(:log_a_checkin)  { create(:biometric_punch_log, business: business, employee: employee_a, biometric_device: device_a, action: "check_in") }
  let!(:log_a_checkout) { create(:biometric_punch_log, business: business, employee: employee_a, biometric_device: device_a, action: "check_out") }
  let!(:log_b_checkin)  { create(:biometric_punch_log, business: business, employee: employee_b, biometric_device: device_b, action: "check_in") }

  def log_paths(logs)
    logs.map { |l| admin_biometric_punch_log_path(l) }
  end

  def rendered_log_paths
    Nokogiri::HTML(response.body).css("table tbody tr td.td-actions a").map { |a| a["href"] }
  end

  def rendered_option_values(select_id)
    Nokogiri::HTML(response.body).at_css("select##{select_id}").css("option").map { |o| o["value"] }
  end

  def selected_option_value(select_id)
    Nokogiri::HTML(response.body).at_css("select##{select_id} option[selected]")&.[]("value")
  end

  # Assignment Branch (branch_id, employees assigned there) vs Actual Branch
  # (actual_branch_id, the branch recorded on the punch log). The default logs
  # above record no branch.
  describe "Assignment Branch and Actual Branch filters" do
    # employee_a (assigned to A) punches at A and at B; employee_b (assigned to B)
    # punches at A.
    let!(:a_at_a) { create(:biometric_punch_log, business: business, employee: employee_a, biometric_device: device_a, branch: branch_a) }
    let!(:a_at_b) { create(:biometric_punch_log, business: business, employee: employee_a, biometric_device: device_b, branch: branch_b) }
    let!(:b_at_a) { create(:biometric_punch_log, business: business, employee: employee_b, biometric_device: device_a, branch: branch_a) }
    let!(:mobile) { create(:biometric_punch_log, business: business, employee: employee_b, source: "mobile", action: "check_in") }

    let(:unrecorded) { [ log_a_checkin, log_a_checkout, log_b_checkin, mobile ] }

    it "lists every log, with or without a branch, when neither filter is set (default unchanged)" do
      get admin_biometric_punch_logs_path

      expect(rendered_log_paths).to match_array(log_paths([ a_at_a, a_at_b, b_at_a ] + unrecorded))
    end

    it "keeps the Assignment Branch filter on the employee's assignment, whatever branch the punch was at" do
      get admin_biometric_punch_logs_path(branch_id: branch_a.id)

      expect(rendered_log_paths).to match_array(log_paths([ a_at_a, a_at_b, log_a_checkin, log_a_checkout ]))
    end

    it "filters by Actual Branch: the punches made at that branch, by any employee" do
      get admin_biometric_punch_logs_path(actual_branch_id: branch_a.id)

      expect(rendered_log_paths).to match_array(log_paths([ a_at_a, b_at_a ]))
    end

    it "selects the logs with no recorded branch with the \"none\" option" do
      get admin_biometric_punch_logs_path(actual_branch_id: "none")

      expect(rendered_log_paths).to match_array(log_paths(unrecorded))
    end

    it "combines both filters: assigned to A, punched at B" do
      get admin_biometric_punch_logs_path(branch_id: branch_a.id, actual_branch_id: branch_b.id)

      expect(rendered_log_paths).to match_array(log_paths([ a_at_b ]))
    end

    it "combines both filters with \"none\": assigned to B, no recorded branch" do
      get admin_biometric_punch_logs_path(branch_id: branch_b.id, actual_branch_id: "none")

      expect(rendered_log_paths).to match_array(log_paths([ log_b_checkin, mobile ]))
    end

    it "ignores an Actual Branch of another business" do
      get admin_biometric_punch_logs_path(actual_branch_id: create(:branch).id)

      expect(rendered_log_paths).to match_array(log_paths([ a_at_a, a_at_b, b_at_a ] + unrecorded))
    end

    it "offers the no-branch option, every branch of the business (inactive marked), and keeps the selection" do
      closed = create(:branch, :inactive, business: business, name: "Closed")
      create(:branch, business: create(:business), name: "Foreign")

      get admin_biometric_punch_logs_path(actual_branch_id: branch_b.id)

      expect(rendered_option_values("actual_branch_id")).to eq([ "", "none", branch_a.id.to_s, branch_b.id.to_s, closed.id.to_s ])
      expect(selected_option_value("actual_branch_id")).to eq(branch_b.id.to_s)
      expect(response.body).to include(I18n.t("admin.biometric_devices.form.branch_inactive_option", name: "Closed"))
      expect(response.body).not_to include("Foreign")
      expect(rendered_option_values("branch_id")).to eq([ "", branch_a.id.to_s, branch_b.id.to_s ])
    end

    it "shows the Actual Branch column" do
      get admin_biometric_punch_logs_path(actual_branch_id: branch_b.id)

      row = Nokogiri::HTML(response.body).at_css("table tbody tr")
      expect(row.text).to include("Branch B")
    end
  end

  describe "GET /admin/biometric_punch_logs" do
    it "filters by branch" do
      get admin_biometric_punch_logs_path(branch_id: branch_a.id)

      expect(rendered_log_paths).to match_array(log_paths([ log_a_checkin, log_a_checkout ]))
    end

    it "filters by employee" do
      get admin_biometric_punch_logs_path(employee_id: employee_b.id)

      expect(rendered_log_paths).to match_array(log_paths([ log_b_checkin ]))
    end

    it "combines branch and employee filters" do
      get admin_biometric_punch_logs_path(branch_id: branch_a.id, employee_id: employee_a.id)

      expect(rendered_log_paths).to match_array(log_paths([ log_a_checkin, log_a_checkout ]))
    end

    it "combines branch, device, and result (action) filters" do
      get admin_biometric_punch_logs_path(branch_id: branch_a.id, device_id: device_a.id, action_filter: "check_in")

      expect(rendered_log_paths).to match_array(log_paths([ log_a_checkin ]))
    end

    it "resets an employee filter that is invalid for the newly selected branch" do
      get admin_biometric_punch_logs_path(branch_id: branch_a.id, employee_id: employee_b.id)

      # employee_b belongs to branch_b, not branch_a — the invalid employee
      # filter is dropped so the branch filter alone applies (not zero results),
      # and the employee dropdown falls back to "all employees" (nothing selected).
      expect(rendered_log_paths).to match_array(log_paths([ log_a_checkin, log_a_checkout ]))
      expect(selected_option_value("employee_id")).to be_nil
    end

    it "shows logs from all branches when no branch is selected" do
      get admin_biometric_punch_logs_path

      expect(rendered_log_paths).to match_array(log_paths([ log_a_checkin, log_a_checkout, log_b_checkin ]))
    end

    it "populates the employee dropdown with all business employees when no branch is selected" do
      get admin_biometric_punch_logs_path

      expect(rendered_option_values("employee_id"))
        .to match_array([ "", owner.id.to_s, employee_a.id.to_s, employee_b.id.to_s ])
    end

    it "restricts the employee dropdown to employees of the selected branch" do
      get admin_biometric_punch_logs_path(branch_id: branch_a.id)

      expect(rendered_option_values("employee_id")).to match_array([ "", employee_a.id.to_s ])
    end

    it "still filters by device alone" do
      get admin_biometric_punch_logs_path(device_id: device_b.id)

      expect(rendered_log_paths).to match_array(log_paths([ log_b_checkin ]))
    end

    it "still filters by result (action) alone" do
      get admin_biometric_punch_logs_path(action_filter: "check_out")

      expect(rendered_log_paths).to match_array(log_paths([ log_a_checkout ]))
    end

    it "preserves recency ordering and the result limit with filters applied" do
      newer = create(:biometric_punch_log, business: business, employee: employee_a, biometric_device: device_a,
                      action: "check_in", received_at: 1.minute.from_now)

      get admin_biometric_punch_logs_path(branch_id: branch_a.id)

      expect(rendered_log_paths.first).to eq(admin_biometric_punch_log_path(newer))
    end

    it "issues a fixed number of queries regardless of the number of matching logs (no N+1)" do
      def count_queries
        queries = 0
        counter = ->(*, payload) { queries += 1 unless payload[:cached] || payload[:sql].start_with?("BEGIN", "COMMIT") }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
        queries
      end

      # Warm up Rails' lazily-populated per-table column/schema cache (e.g. for
      # active_storage_attachments, touched via the layout's user avatar) so it
      # doesn't get mistaken for N+1 noise in the counts below. Two rounds
      # because different attachment columns can get first-touched on
      # different requests depending on association load order.
      get admin_biometric_punch_logs_path
      get admin_biometric_punch_logs_path

      small_count = count_queries { get admin_biometric_punch_logs_path }

      create_list(:biometric_punch_log, 20, business: business, employee: employee_a, biometric_device: device_a)

      large_count = count_queries { get admin_biometric_punch_logs_path }

      expect(large_count).to eq(small_count)
    end
  end
end
