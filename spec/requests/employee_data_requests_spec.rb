require "rails_helper"

RSpec.describe "Employee data requests", type: :request do
  let(:business) { create(:business).tap { |b| seed_job_titles(b) } }
  let(:manager)  { edr_manager(business: business, preferred_locale: "ar") }
  let(:reviewer) { edr_reviewer(business: business, preferred_locale: "ar") }
  let!(:managed_branch) do
    create(:branch, business: business).tap { |b| b.update_column(:branch_manager_id, manager.id) }
  end

  describe "manager submission" do
    before { sign_in manager }

    it "renders the Arabic form with personal-data fields only" do
      get new_employee_data_request_path
      expect(response).to have_http_status(:ok)
      html = Nokogiri::HTML(response.body)
      expect(html.at_css("html")["dir"]).to eq("rtl")
      expect(response.body).to include("الاسم بالكامل", "الرقم القومي", "صورة البطاقة - الوجه الأمامي",
                                       "ملاحظات المدير", "إرسال للمراجعة")
      names = html.css("form.edr-form [name]").map { |n| n["name"] }
      expect(names.grep(/branch|salary|permission|shift|commission|payroll/)).to be_empty
    end

    it "shows every employee basic-data field and no employment configuration" do
      get new_employee_data_request_path
      names = Nokogiri::HTML(response.body).css("form.edr-form [name]").map { |n| n["name"] }
      EmployeeDataRequestRevision::DATA_FIELDS.each do |field|
        expect(names).to include("employee_data_request[#{field}]")
      end
      expect(names).to include("employee_data_request[id_front]", "employee_data_request[id_back]",
                               "employee_data_request[manager_notes]")
      expect(names.grep(/branch|salary|permission|role|shift|commission|payroll/)).to be_empty
    end

    it "stores all submitted employee fields on the request" do
      post employee_data_requests_path, params: { employee_data_request: edr_params }
      revision = EmployeeDataRequest.last.revisions.first
      expect(revision).to have_attributes(
        full_name: "محمد أحمد علي حسن", national_id: "29501011234567", phone_number: "01001234567",
        date_of_birth: Date.new(1995, 1, 1), identity_card_expiry_date: Date.new(2031, 5, 20),
        job_title: "كوافير", hire_date: Date.new(2026, 10, 1), emergency_contact_name: "فاطمة حسن",
        emergency_contact_phone: "01229876543", emergency_contact_relationship: "والدة"
      )
    end

    it "blocks submission without the emergency phone" do
      post employee_data_requests_path, params: { employee_data_request: edr_params(emergency_contact_phone: "") }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("رقم هاتف الطوارئ")
      expect(EmployeeDataRequest.count).to eq(0)
      get new_employee_data_request_path
      expect(Nokogiri::HTML(response.body).at_css("#edr_emergency_contact_phone")["required"]).to be_present
    end

    %i[hire_date identity_card_expiry_date].each do |field|
      it "blocks submission without #{field}" do
        post employee_data_requests_path, params: { employee_data_request: edr_params(field => "") }
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t("employee_data_requests.fields.#{field}", locale: :ar))
        expect(EmployeeDataRequest.count).to eq(0)
        get new_employee_data_request_path
        expect(Nokogiri::HTML(response.body).at_css("#edr_#{field}")["required"]).to be_present
      end
    end

    it "accepts a request without an address" do
      post employee_data_requests_path, params: { employee_data_request: edr_params(address: "") }
      expect(response).to redirect_to(employee_data_request_path(EmployeeDataRequest.last))
      expect(EmployeeDataRequest.last.revisions.first.address).to be_nil
      get new_employee_data_request_path
      expect(Nokogiri::HTML(response.body).at_css("#edr_address")["required"]).to be_nil
    end

    it "offers exactly the same job-title options as the employee creation form" do
      create(:job_title, business: business, name: "مدير فرع سابق", active: false)
      sign_in edr_user_with(*EmployeeDataRequestHelpers::EDR_REQUESTER_PERMISSIONS, :view_employees, :manage_employees, business: business)

      get new_employee_data_request_path
      request_options = Nokogiri::HTML(response.body).css("#edr_job_title option").map { |o| o["value"] }
      get new_admin_user_path
      employee_options = Nokogiri::HTML(response.body).css("select#user_job_title option").map { |o| o["value"] }

      expect(request_options).to eq(employee_options)
      expect(request_options.compact_blank).to eq(JobTitle.where(business: business).active.ordered.pluck(:name))
      expect(request_options).not_to include("مدير فرع سابق")
    end

    it "rejects a job title that is not in the managed list" do
      post employee_data_requests_path, params: { employee_data_request: edr_params(job_title: "وظيفة مخترعة") }
      expect(response).to have_http_status(:unprocessable_content)
      expect(EmployeeDataRequest.count).to eq(0)
    end

    it "creates a pending request without touching employees" do
      expect {
        post employee_data_requests_path, params: { employee_data_request: edr_params(manager_notes: "مرتب 9000 جنيه + عمولة") }
      }.to change(EmployeeDataRequest, :count).by(1).and change(User, :count).by(0)

      request = EmployeeDataRequest.last
      expect(response).to redirect_to(employee_data_request_path(request))
      expect(request).to be_pending_review
      expect(SalaryProfile.count).to eq(0)
    end

    it "re-renders with errors when the ID photos are missing" do
      post employee_data_requests_path, params: { employee_data_request: edr_params(id_front: nil, id_back: nil) }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("صورة البطاقة - الوجه الأمامي", "صورة البطاقة - الوجه الخلفي")
      expect(EmployeeDataRequest.count).to eq(0)
    end

    it "ignores a smuggled branch/salary param" do
      post employee_data_requests_path,
           params: { employee_data_request: edr_params.merge(branch_id: managed_branch.id, salary: 9000) }
      expect(EmployeeDataRequest.last).to be_present
    end
  end

  describe "access control" do
    let!(:request_record) { create(:employee_data_request, business: business, submitted_by: manager) }

    it "blocks users without permission from the list, the request, and the ID photos" do
      sign_in create(:user, business: business)
      get employee_data_requests_path
      expect(response).to redirect_to(root_path)
      get employee_data_request_path(request_record)
      expect(response).to redirect_to(root_path)
      get document_employee_data_request_path(request_record, side: "front")
      expect(response).to redirect_to(root_path)
    end

    it "blocks another manager from opening someone else's request by ID" do
      sign_in edr_manager(business: business)
      get employee_data_request_path(request_record)
      expect(response).to redirect_to(root_path)
      get document_employee_data_request_path(request_record, side: "back")
      expect(response).to redirect_to(root_path)
    end

    it "404s for a request in another business" do
      sign_in edr_reviewer(business: create(:business))
      get employee_data_request_path(request_record)
      expect(response).to have_http_status(:not_found)
    end

    it "streams ID photos to the reviewer only via the authorized action, never cached" do
      sign_in reviewer
      get document_employee_data_request_path(request_record, side: "front")
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(response.headers["Content-Disposition"]).to start_with("inline")
    end

    it "never renders public Active Storage URLs or the national ID in links" do
      sign_in reviewer
      get employee_data_request_path(request_record)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("/rails/active_storage")
      national_id = request_record.revisions.first.national_id
      hrefs = Nokogiri::HTML(response.body).css("[href],[src],[action]").map { |n| n["href"] || n["src"] || n["action"] }
      expect(hrefs.grep(/#{national_id}/)).to be_empty
    end

    it "shows the manager notes to the reviewer" do
      sign_in reviewer
      get employee_data_request_path(create(:employee_data_request, business: business, submitted_by: manager,
                                                                    manager_notes: "مرتب 9000 جنيه"))
      expect(response.body).to include("مرتب 9000 جنيه")
    end
  end

  describe "review flow" do
    let!(:request_record) { create(:employee_data_request, business: business, submitted_by: manager) }

    it "reviewer sees the pending request prominently in the list" do
      sign_in reviewer
      get employee_data_requests_path
      expect(response.body).to include("بانتظار مراجعتك")
      expect(response.body).to include("الموظف", "مقدم الطلب", "تاريخ الطلب", "الحالة", "آخر تحديث", "المراجع")
    end

    it "approves, creating the employee without branch/salary/permissions/shifts" do
      sign_in reviewer
      expect { patch approve_employee_data_request_path(request_record) }.to change(User, :count).by(1)
      employee = request_record.reload.employee
      expect(request_record).to be_approved
      expect(employee.permission_role_id).to be_nil
      expect(employee.salary_profiles).to be_empty
      expect(employee.shift_assignments).to be_empty
      expect(managed_branch.reload.branch_manager_id).to eq(manager.id)
    end

    it "rejects only with a reason" do
      sign_in reviewer
      patch reject_employee_data_request_path(request_record), params: { note: "" }
      expect(request_record.reload).to be_pending_review
      patch reject_employee_data_request_path(request_record), params: { note: "البيانات غير مطابقة" }
      expect(request_record.reload).to be_rejected
    end

    it "requests changes, then the manager resubmits and it returns to pending review" do
      sign_in reviewer
      patch request_changes_employee_data_request_path(request_record),
            params: { note: "صورة البطاقة الخلفية غير واضحة، برجاء إعادة رفعها." }
      expect(request_record.reload).to be_changes_requested

      sign_in manager
      get edit_employee_data_request_path(request_record)
      expect(response.body).to include("صورة البطاقة الخلفية غير واضحة")

      rev = request_record.revisions.first
      patch employee_data_request_path(request_record),
            params: { employee_data_request: edr_params(national_id: rev.national_id, id_front: nil) }
      expect(response).to redirect_to(employee_data_request_path(request_record))
      expect(request_record.reload).to be_pending_review
      expect(request_record.revisions.count).to eq(2)
      expect(request_record.events.pluck(:action)).to eq(%w[submitted changes_requested resubmitted])
    end

    it "reviewer corrects fields, sees submitted vs corrected, then approves without re-entering data" do
      sign_in reviewer
      get employee_data_request_path(request_record)
      html = Nokogiri::HTML(response.body)
      expect(html.at_css("[data-testid='review-form']")).to be_present
      expect(html.at_css("#review_job_title option[selected]")["value"]).to eq("كوافير")

      patch correct_employee_data_request_path(request_record),
            params: { employee_data_request: { job_title: "مديرة صالون", hire_date: "2026-11-15" } }
      expect(response).to redirect_to(employee_data_request_path(request_record))

      get employee_data_request_path(request_record)
      html = Nokogiri::HTML(response.body)
      expect(html.at_css("#review_job_title option[selected]")["value"]).to eq("مديرة صالون")
      expect(html.at_css("[data-testid='submitted-job_title']").text).to include("كوافير")
      expect(html.at_css("[data-testid='correction-diff']").text).to include("كوافير", "مديرة صالون")

      # Approving submits the (already corrected) form values — nothing new to type.
      patch approve_employee_data_request_path(request_record),
            params: { employee_data_request: html.css("#edr-review-form [name^='employee_data_request']").to_h { |n|
                        value = n.name == "select" ? n.at_css("option[selected]")&.[]("value") : (n["value"] || n.text)
                        [ n["name"][/\[(.+)\]/, 1], value ]
                      } }
      employee = request_record.reload.employee
      expect(employee).to have_attributes(job_title: "مديرة صالون", hire_date: Date.new(2026, 11, 15),
                                          emergency_contact_name: "فاطمة حسن", identity_card_expiry_date: Date.new(2031, 5, 20))
      expect(request_record.revisions.count).to eq(2)
    end

    it "re-renders the review form with errors for an invalid correction" do
      sign_in reviewer
      patch approve_employee_data_request_path(request_record),
            params: { employee_data_request: { national_id: "123" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(Nokogiri::HTML(response.body).at_css("#review_national_id")["value"]).to eq("123")
      expect(request_record.reload).to be_pending_review
      expect(request_record.employee).to be_nil
    end

    it "hides reviewer-only details from the requesting manager" do
      sign_in reviewer
      patch correct_employee_data_request_path(request_record), params: { employee_data_request: { job_title: "مديرة صالون" } }

      sign_in manager
      get employee_data_request_path(request_record)
      html = Nokogiri::HTML(response.body)
      expect(response).to have_http_status(:ok)
      %w[verification-checks review-form review-actions correction-diff submitted-job_title].each do |testid|
        expect(html.at_css("[data-testid='#{testid}']")).to be_nil, "requester saw #{testid}"
      end
      expect(response.body).not_to include(I18n.t("employee_data_requests.checks.title", locale: :ar))
      # The requester still sees the status and the current basic data.
      expect(html.at_css("[data-testid='field-job_title']").text).to include("مديرة صالون")
      expect(html.at_css("select#review_job_title")).to be_nil
      expect(response.body).to include("بانتظار المراجعة")
    end

    it "shows the reviewer the verification checks" do
      sign_in reviewer
      get employee_data_request_path(request_record)
      expect(Nokogiri::HTML(response.body).at_css("[data-testid='verification-checks']")).to be_present
    end

    it "does not let the manager correct their own request" do
      sign_in manager
      patch correct_employee_data_request_path(request_record), params: { employee_data_request: { job_title: "x" } }
      expect(response).to redirect_to(root_path)
      expect(request_record.reload.revisions.count).to eq(1)
    end

    it "does not let the manager approve their own request" do
      sign_in manager
      patch approve_employee_data_request_path(request_record)
      expect(request_record.reload).to be_pending_review
    end
  end
end

RSpec.describe "Employee data requests — server-side authorization", type: :request do
  let(:business)  { create(:business).tap { |b| seed_job_titles(b) } }
  let(:requester) { edr_manager(business: business, preferred_locale: "ar") }
  let!(:request_record) { create(:employee_data_request, business: business, submitted_by: requester) }
  let(:view_all)  { %i[view_employee_requests view_all_employee_requests] }

  def user_with(*perms)
    edr_user_with(*perms, business: business, scopes: { view_all_employee_requests: "business" }.slice(*perms))
  end

  def page_for(user)
    sign_in user
    get employee_data_request_path(request_record)
    Nokogiri::HTML(response.body)
  end

  def testids(html) = html.css("[data-testid]").map { |n| n["data-testid"] }

  it "blocks a user without create_employee_requests from the form and the create endpoint" do
    sign_in user_with(:view_employee_requests)
    get new_employee_data_request_path
    expect(response).to redirect_to(root_path)
    expect { post employee_data_requests_path, params: { employee_data_request: edr_params } }
      .not_to change(EmployeeDataRequest, :count)
  end

  it "rejects every reviewer/approver endpoint called directly by the requester" do
    sign_in requester
    patch approve_employee_data_request_path(request_record)
    patch reject_employee_data_request_path(request_record), params: { note: "x" }
    patch request_changes_employee_data_request_path(request_record), params: { note: "x" }
    patch correct_employee_data_request_path(request_record), params: { employee_data_request: { job_title: "ريسبشن" } }
    expect(request_record.reload).to be_pending_review
    expect(request_record.revisions.count).to eq(1)
    expect(User.where(identity_card_number: request_record.revisions.first.national_id)).to be_empty
  end

  it "blocks approval with review permission only" do # 8 / 14
    sign_in user_with(*view_all, :review_employee_requests)
    patch approve_employee_data_request_path(request_record)
    expect(response).to redirect_to(root_path)
    expect(request_record.reload).to be_pending_review
  end

  it "blocks rejection without reject_employee_requests" do # 10 / 14
    sign_in user_with(*view_all, :review_employee_requests, :approve_employee_requests)
    patch reject_employee_data_request_path(request_record), params: { note: "سبب" }
    expect(request_record.reload).to be_pending_review
    sign_in user_with(*view_all, :reject_employee_requests)
    patch reject_employee_data_request_path(request_record), params: { note: "سبب" }
    expect(request_record.reload).to be_rejected
  end

  it "blocks returning for changes without request_employee_changes, then the requester resubmits" do # 11, 12
    sign_in user_with(*view_all, :review_employee_requests)
    patch request_changes_employee_data_request_path(request_record), params: { note: "أعد رفع الصورة" }
    expect(request_record.reload).to be_pending_review

    sign_in user_with(*view_all, :request_employee_changes)
    patch request_changes_employee_data_request_path(request_record), params: { note: "أعد رفع الصورة" }
    expect(request_record.reload).to be_changes_requested

    sign_in requester
    patch employee_data_request_path(request_record),
          params: { employee_data_request: edr_params(national_id: request_record.revisions.first.national_id) }
    expect(request_record.reload).to be_pending_review
    expect(request_record.revisions.count).to eq(2)
  end

  it "lets an approver approve but not change the data without review permission" do
    approver = user_with(*view_all, :approve_employee_requests)
    sign_in approver
    patch approve_employee_data_request_path(request_record), params: { employee_data_request: { job_title: "ريسبشن" } }
    expect(response).to redirect_to(root_path)
    expect(request_record.reload).to be_pending_review

    patch approve_employee_data_request_path(request_record)
    expect(request_record.reload).to be_approved
    expect(request_record.employee.job_title).to eq("كوافير")
  end

  it "never lets someone approve their own request, even with every permission" do # 9 / 14
    self_approver = user_with(*EmployeeDataRequestHelpers::EDR_REVIEWER_PERMISSIONS, :create_employee_requests)
    own = create(:employee_data_request, business: business, submitted_by: self_approver)
    sign_in self_approver
    patch approve_employee_data_request_path(own)
    expect(response).to redirect_to(root_path)
    expect(own.reload).to be_pending_review
  end

  it "denies requests outside the reviewer's scope, even by direct URL" do # 7
    branch = create(:branch, business: business)
    reviewer = edr_user_with(*view_all, :review_employee_requests, :approve_employee_requests, business: business,
                             scopes: { view_all_employee_requests: "branch" })
    branch.update_column(:branch_manager_id, reviewer.id)
    sign_in reviewer
    get employee_data_request_path(request_record)
    expect(response).to redirect_to(root_path)
    get document_employee_data_request_path(request_record, side: "front")
    expect(response).to redirect_to(root_path)
    patch approve_employee_data_request_path(request_record)
    expect(request_record.reload).to be_pending_review
    get employee_data_requests_path
    expect(response.body).not_to include(request_record.revisions.first.full_name)
  end

  it "serves no JSON/XML representation, even to the owner" do
    owner = create(:user, business: business).tap { |u| business.update!(owner: u) }
    sign_in owner
    get employee_data_request_path(request_record, format: :json)
    expect(response).to have_http_status(:not_acceptable)
    expect(response.body).not_to include(request_record.revisions.first.national_id)
    get employee_data_requests_path(format: :json)
    expect(response).to have_http_status(:not_acceptable)
  end

  describe "UI shows only permitted actions (hidden, not disabled)" do
    it "requester: status and data, no reviewer details or controls" do # 5
      html = page_for(requester)
      ids = testids(html)
      expect(ids).to include("status-note", "employee-data", "documents")
      expect(ids).not_to include("verification-checks", "review-form", "review-actions", "approve-button",
                                 "reject-action", "request-changes-action", "save-corrections-button")
      expect(html.css("button[disabled], input[disabled]")).to be_empty
    end

    it "reviewer: review form, checks and documents, but no decision buttons" do
      ids = testids(page_for(user_with(*view_all, :review_employee_requests)))
      expect(ids).to include("review-form", "verification-checks", "documents", "save-corrections-button")
      expect(ids).not_to include("approve-button", "reject-action", "request-changes-action")
    end

    it "approver only: approve button, no review form, checks or documents" do
      ids = testids(page_for(user_with(*view_all, :approve_employee_requests)))
      expect(ids).to include("approve-button")
      expect(ids).not_to include("review-form", "verification-checks", "documents", "reject-action",
                                 "request-changes-action", "save-corrections-button")
    end

    it "each decision appears only with its own permission" do
      expect(testids(page_for(user_with(*view_all, :reject_employee_requests))))
        .to include("reject-action").and(not_include("approve-button", "request-changes-action"))
      expect(testids(page_for(user_with(*view_all, :request_employee_changes))))
        .to include("request-changes-action").and(not_include("approve-button", "reject-action"))
    end

    it "shows the sidebar entry and New Request button only with the matching permissions" do
      sign_in create(:user, business: business)
      get root_path
      expect(response.body).not_to include(employee_data_requests_path)

      sign_in user_with(*view_all)
      get employee_data_requests_path
      expect(response.body).to include(employee_data_requests_path)
      expect(response.body).not_to include(new_employee_data_request_path)

      sign_in requester
      get employee_data_requests_path
      expect(response.body).to include(new_employee_data_request_path)
    end

    it "super admin sees every control" do # 13
      owner = create(:user, business: business).tap { |u| business.update!(owner: u) }
      ids = testids(page_for(owner))
      expect(ids).to include("review-form", "verification-checks", "documents", "approve-button",
                             "reject-action", "request-changes-action", "save-corrections-button")
    end
  end
end
