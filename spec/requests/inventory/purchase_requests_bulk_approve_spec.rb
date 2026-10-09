require "rails_helper"

RSpec.describe "Purchase Requests — bulk approval", type: :request do
  let(:business)  { create(:business) }
  let(:requester) { create(:user, business: business) }
  let(:approver) do
    role = business.permission_roles.create!(name: "PR Approver", permissions: %w[view_inventory approve_purchase_requests])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end
  let(:viewer) do
    role = business.permission_roles.create!(name: "Viewer", permissions: %w[view_inventory])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end
  let(:product) { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 1) }

  def request_with(total:, status: "pending_approval", supplier: nil, submitted_by: requester)
    pr = business.purchase_requests.build(supplier: supplier, created_by: requester)
    pr.items.build(product: product, quantity: 1, unit_price: total)
    pr.save!
    pr.update_columns(status: status, submitted_by_id: submitted_by.id)
    pr
  end

  describe "POST /inventory/purchase_requests/bulk_approve" do
    it "approves all selected requests (supplier-less included) and flashes the count and total" do
      prs = [ request_with(total: 2200), request_with(total: 242), request_with(total: 600) ]
      sign_in approver

      post bulk_approve_inventory_purchase_requests_path,
           params: { purchase_request_ids: prs.map(&:id) },
           headers: { "HTTP_REFERER" => inventory_purchase_requests_url(status: "pending_approval") }

      expect(response).to redirect_to(inventory_purchase_requests_url(status: "pending_approval"))
      expect(flash[:notice]).to eq(I18n.t("inventory.purchase_requests.bulk_approved", count: 3, total: "SAR 3,042.00"))
      expect(prs.map { |pr| pr.reload.status }).to all(eq("approved"))

      follow_redirect!
      expect(response.body).not_to include(prs.first.request_number) # gone from the pending filter
    end

    it "AR: shows the Arabic success message" do
      prs = [ request_with(total: 2200), request_with(total: 842) ]
      approver.update!(preferred_locale: "ar")
      sign_in approver

      post bulk_approve_inventory_purchase_requests_path, params: { purchase_request_ids: prs.map(&:id) }

      expect(flash[:notice]).to start_with("تم اعتماد 2 طلبات شراء بإجمالي 3,042.00")
    end

    it "answers JSON with success, approved_count and an exact decimal total" do
      prs = [ request_with(total: "2200.10"), request_with(total: "241.90") ]
      sign_in approver

      post bulk_approve_inventory_purchase_requests_path(format: :json), params: { purchase_request_ids: prs.map(&:id) }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("success" => true, "approved_count" => 2, "total_amount" => "2442.00")
    end

    it "fails as a whole when a request changed state, approving nothing" do
      a = request_with(total: 100)
      b = request_with(total: 200, status: "approved")
      sign_in approver

      post bulk_approve_inventory_purchase_requests_path(format: :json), params: { purchase_request_ids: [ a.id, b.id ] }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include(b.request_number)
      expect(a.reload).to be_pending_approval
    end

    it "rejects an empty selection" do
      sign_in approver

      post bulk_approve_inventory_purchase_requests_path

      expect(flash[:alert]).to eq(I18n.t("inventory.purchase_requests.errors.bulk_none_selected"))
    end

    it "denies a user without the approve permission and approves nothing" do
      pr = request_with(total: 100)
      sign_in viewer

      post bulk_approve_inventory_purchase_requests_path, params: { purchase_request_ids: [ pr.id ] }

      expect(flash[:alert]).to be_present
      expect(pr.reload).to be_pending_approval
    end
  end

  describe "GET /inventory/purchase_requests (selection UI)" do
    it "enables checkboxes only for requests this user may approve, with reasons on the others" do
      pending  = request_with(total: 100)
      draft    = request_with(total: 50, status: "draft")
      approved = request_with(total: 70, status: "approved")
      own      = request_with(total: 80, submitted_by: approver)
      sign_in approver

      get inventory_purchase_requests_path

      doc = Nokogiri::HTML(response.body)
      box = ->(pr) { doc.at_css(".pr-bulk-check-row[value='#{pr.id}']") }
      expect(box.(pending)["disabled"]).to be_nil
      expect(box.(pending)["data-amount"]).to eq("100.0")
      expect(box.(draft)["title"]).to eq(I18n.t("inventory.purchase_requests.bulk.not_selectable_status"))
      expect(box.(approved)["disabled"]).to be_present
      expect(box.(own)["title"]).to eq(I18n.t("inventory.purchase_requests.bulk.not_selectable_self"))
      expect(doc.at_css(".pr-bulk-check-all")).to be_present
    end

    it "shows no selection column to a user who cannot approve" do
      request_with(total: 100)
      sign_in viewer

      get inventory_purchase_requests_path

      expect(response.body).not_to include("pr-bulk-check-row")
      expect(response.body).not_to include(bulk_approve_inventory_purchase_requests_path)
    end
  end
end
