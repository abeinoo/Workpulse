require "rails_helper"

# "الموظف المسؤول عن الشراء" on the Purchase Request pages: optional on the form
# and the Low Stock batch (eligible employees only when chosen), shown on the
# index and show page, assigned later through the audited action, and required
# before any advance can be recorded.
RSpec.describe "Purchase Request responsible employee (HTTP)", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main WH") }
  let!(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 100) }
  let!(:rami) { purchaser_with_custody(business, first_name: "Rami", last_name: "Saad") }

  def user_with(*permissions)
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def approved_request(responsible: nil)
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: owner, responsible_employee: responsible)
    pr.items.build(product: product, quantity: 2, unit_price: 100)
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def html = Nokogiri::HTML(response.body)

  describe "the request form" do
    it "offers only eligible employees (permission + active custody account), as an optional field" do
      create(:custody_account, business: business, user: create(:user, business: business, first_name: "Karim"))
      sign_in owner
      get new_inventory_purchase_request_path

      select = html.at_css("select[name='purchase_request[responsible_employee_id]']")
      expect(select["required"]).to be_nil
      expect(select.css("option").map(&:text).compact_blank.drop(1)).to eq([ rami.full_name ])
    end

    it "creates the request without an employee, or with the chosen one; refuses an ineligible one" do
      sign_in owner
      submit = ->(responsible_id) {
        post inventory_purchase_requests_path, params: {
          idempotency_key: SecureRandom.uuid,
          purchase_request: { warehouse_id: warehouse.id, responsible_employee_id: responsible_id,
                              items_attributes: { "0" => { product_id: product.id, quantity: 1, unit_price: 10 } } }
        }
      }

      expect { submit.("") }.to change(PurchaseRequest, :count).by(1)
      expect(PurchaseRequest.last.responsible_employee_id).to be_nil # never the logged-in user

      expect { submit.(rami.id) }.to change(PurchaseRequest, :count).by(1)
      expect(PurchaseRequest.last.responsible_employee).to eq(rami)

      no_permission = create(:user, business: business).tap { |u| create(:custody_account, business: business, user: u) }
      expect { submit.(no_permission.id) }.not_to change(PurchaseRequest, :count)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.responsible_employee_ineligible"))
    end

    it "the Low Stock review modal posts one optional responsible employee for the batch" do
      sign_in owner
      expect {
        post inventory_purchase_requests_path, params: {
          idempotency_key: SecureRandom.uuid, responsible_employee_id: rami.id,
          items: [ { product_id: product.id, quantity: 3, unit_price: 100, warehouse_id: warehouse.id } ]
        }
      }.to change(PurchaseRequest, :count).by(1)
      expect(PurchaseRequest.last.responsible_employee).to eq(rami)

      expect {
        post inventory_purchase_requests_path, params: {
          idempotency_key: SecureRandom.uuid,
          items: [ { product_id: product.id, quantity: 3, unit_price: 100, warehouse_id: warehouse.id } ]
        }
      }.to change(PurchaseRequest, :count).by(1)
      expect(PurchaseRequest.last.responsible_employee_id).to be_nil
    end
  end

  describe "index and show" do
    it "shows the responsible employee, and \"Not assigned\" for a legacy request" do
      assigned = approved_request(responsible: rami)
      legacy   = approved_request
      sign_in owner

      get inventory_purchase_requests_path
      rows = html.css("[data-testid='pr-responsible']").map { |n| n.text.squish }
      expect(rows).to include(a_string_including(rami.full_name),
                              a_string_including(I18n.t("inventory.purchase_requests.responsible_not_assigned")))

      get inventory_purchase_request_path(assigned)
      expect(html.at_css("[data-testid='pr-responsible-employee']").text).to include(rami.full_name)
      get inventory_purchase_request_path(legacy)
      expect(html.at_css("[data-testid='pr-responsible-employee']").text)
        .to include(I18n.t("inventory.purchase_requests.responsible_not_assigned"))
      expect(response.body).to include(I18n.t("inventory.purchase_requests.responsible_missing_title"))
    end
  end

  describe "POST assign_responsible_employee" do
    it "assigns it on an approved legacy request for an approver, audited" do
      legacy = approved_request
      sign_in user_with("view_inventory", "approve_purchase_requests")

      post assign_responsible_employee_inventory_purchase_request_path(legacy), params: { responsible_employee_id: rami.id }
      expect(response).to redirect_to(inventory_purchase_request_path(legacy))
      expect(flash[:notice]).to eq(I18n.t("inventory.purchase_requests.responsible_employee_assigned"))
      expect(legacy.reload.responsible_employee).to eq(rami)
      expect(AuditLog.where(auditable: legacy, action: "assign_responsible_employee")).to exist
    end

    it "is denied without approve_purchase_requests / manage_inventory" do
      legacy = approved_request
      sign_in user_with("view_inventory", "create_purchase_requests")

      post assign_responsible_employee_inventory_purchase_request_path(legacy), params: { responsible_employee_id: rami.id }
      expect(legacy.reload.responsible_employee).to be_nil
    end

    it "shows the lock while a funding advance is pending" do
      pr = approved_request(responsible: rami)
      Inventory::PurchaseRequestAdvanceRecorder.new(
        purchase_request_id: pr.id, actor: owner, params: { amount: 50, source_kind: "company_cash", paid_on: Date.current }
      ).call
      sign_in owner

      get inventory_purchase_request_path(pr)
      expect(html.at_css("[data-testid='responsible-locked']")).to be_present

      post assign_responsible_employee_inventory_purchase_request_path(pr),
           params: { responsible_employee_id: purchaser_with_custody(business).id }
      expect(flash[:alert]).to eq(I18n.t("inventory.purchase_requests.errors.responsible_employee_locked"))
      expect(pr.reload.responsible_employee).to eq(rami)
    end
  end

  describe "the advance form" do
    it "shows a blocking state with the next step when the request has no responsible employee" do
      legacy = approved_request
      sign_in owner
      get new_inventory_purchase_request_advance_path(legacy)

      expect(html.at_css("[data-testid='advance-needs-responsible']").text)
        .to include(I18n.t("inventory.purchase_request_advances.needs_responsible_title"))
      expect(html.at_css("form[action='#{inventory_purchase_request_advances_path(legacy)}']")).to be_nil
      expect(response.body).to include(inventory_purchase_request_path(legacy, anchor: "responsible-employee"))
    end

    it "names the employee being credited and never offers their own account as the source" do
      pr = approved_request(responsible: rami)
      sign_in owner
      get new_inventory_purchase_request_advance_path(pr)

      expect(html.at_css("[data-testid='recipient-name']").text).to eq(rami.full_name)
      sources = html.css("select[name='purchase_request_advance[custody_account_id]'] option").map { |o| o["value"] }.compact_blank
      expect(sources).not_to include(custody_of(rami).id.to_s)
    end
  end

  describe "advances need a responsible employee" do
    let(:recorder) { user_with("view_inventory", "manage_purchase_request_advances") }

    def post_advance(request)
      post inventory_purchase_request_advances_path(request), params: {
        idempotency_key: SecureRandom.uuid,
        purchase_request_advance: { amount: 50, source_kind: "company_cash", paid_on: Date.current.to_s }
      }
    end

    it "disables Add Advance with the Arabic explanation while none is assigned" do
      unassigned = approved_request
      recorder.update!(preferred_locale: "ar")
      sign_in recorder
      get inventory_purchase_request_path(unassigned)

      expect(html.at_css("[data-testid='add-advance-disabled']")["disabled"]).to be_present
      expect(response.body).not_to include(new_inventory_purchase_request_advance_path(unassigned))
      expect(html.at_css("[data-testid='advance-needs-responsible-hint']").text)
        .to include("يجب تعيين الموظف المسؤول عن الشراء أولاً قبل إضافة دفعة مقدمة.")
    end

    it "refuses a direct POST without one, and records the advance once one is assigned" do
      unassigned = approved_request
      sign_in recorder

      expect { post_advance(unassigned) }.not_to change(PurchaseRequestAdvance, :count)
      expect(response).to have_http_status(:unprocessable_content)
      # Re-rendered in its blocking state: the explanation and the next step.
      expect(html.at_css("[data-testid='advance-needs-responsible']").text)
        .to include(I18n.t("inventory.purchase_request_advances.needs_responsible_title"))

      Inventory::PurchaseRequestResponsibleAssigner.new(unassigned.id, actor: owner, responsible_employee_id: rami.id).call
      expect { post_advance(unassigned) }.to change(PurchaseRequestAdvance, :count).by(1)
      expect(PurchaseRequestAdvance.last.recipient_custody_account_id).to eq(custody_of(rami).id)

      get inventory_purchase_request_path(unassigned)
      expect(response.body).to include(new_inventory_purchase_request_advance_path(unassigned))
      expect(html.at_css("[data-testid='add-advance-disabled']")).to be_nil
    end
  end
end
