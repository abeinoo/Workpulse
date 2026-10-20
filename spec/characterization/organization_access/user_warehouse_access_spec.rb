require "rails_helper"

# Characterization (Batch W — warehouse access write boundary) — CURRENT writes
# of Inventory & Purchasing WarehouseAssignment rows through the Organization &
# Access employee form (module-boundaries.md §14.2 #10): the
# assigned_warehouse_ids attribute (UserPolicy::ACCOUNT_ATTRIBUTES) assigned by
# Admin::UsersController#create / #update. Authorization of the tier is pinned
# by spec/requests/security/organization_access_{security,scope_hierarchy}_spec.rb;
# the fail-open read rule by spec/characterization/organization_access/access_contracts_spec.rb.
#
# Requests that end in a rescued error are kept one per example.
RSpec.describe "Characterization: warehouse access through the employee form", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:employee) { create(:user, business: business, first_name: "Sara", last_name: "Ali") }

  let!(:main_wh)    { Warehouse.create!(business: business, name: "Main") }
  let!(:second_wh)  { Warehouse.create!(business: business, name: "Second") }
  let!(:foreign_wh) { Warehouse.create!(business: other, name: "Foreign") }

  before { sign_in owner }

  def update_employee(attributes) = patch(admin_user_path(employee), params: { user: { first_name: "Sara" }.merge(attributes) })
  def assigned = employee.reload.assigned_warehouses.order(:id).pluck(:id)

  describe "update" do
    before { employee.assigned_warehouses << main_wh }

    it "replaces the assigned set with the submitted ids (the form's blank hidden value ignored)" do
      update_employee(assigned_warehouse_ids: [ "", second_wh.id.to_s ])

      expect(response).to redirect_to(admin_users_path)
      expect(assigned).to eq([ second_wh.id ])
    end

    it "clears every assignment when only the blank value is submitted — the user becomes unrestricted (fail-open)" do
      update_employee(assigned_warehouse_ids: [ "" ])

      expect(response).to redirect_to(admin_users_path)
      expect(assigned).to be_empty
      expect(employee.reload.inventory_warehouse_ids).to be_nil
    end

    it "leaves the assignments alone when the field is not submitted" do
      update_employee(last_name: "Changed")

      expect(response).to redirect_to(admin_users_path)
      expect(assigned).to eq([ main_wh.id ])
    end

    # Rails' has_many :through ids writer saves the join rows immediately for a
    # persisted record, during assign_attributes — before validation.
    it "keeps the new assignments even when the rest of the form fails validation (422) — not atomic" do
      update_employee(first_name: "", assigned_warehouse_ids: [ "", second_wh.id.to_s ])

      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.reload.first_name).to eq("Sara")
      expect(assigned).to eq([ second_wh.id ])
    end

    it "keeps the new assignments even when the role change is refused (422) — not atomic" do
      foreign_role = create(:permission_role, business: other, permissions: %w[view_employees])

      update_employee(permission_role_id: foreign_role.id, assigned_warehouse_ids: [ "", second_wh.id.to_s ])

      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.reload.permission_role_id).not_to eq(foreign_role.id)
      expect(assigned).to eq([ second_wh.id ])
    end

    it "refuses another business's warehouse (422) and keeps the existing assignments" do
      update_employee(assigned_warehouse_ids: [ "", foreign_wh.id.to_s ])

      expect(response).to have_http_status(:unprocessable_entity)
      expect(WarehouseAssignment.where(warehouse: foreign_wh)).to be_empty
      expect(assigned).to eq([ main_wh.id ])
    end

    it "returns 404 for an unknown warehouse id and keeps the existing assignments" do
      update_employee(assigned_warehouse_ids: [ "", (Warehouse.maximum(:id) + 1000).to_s ])

      expect(response).to have_http_status(:not_found)
      expect(assigned).to eq([ main_wh.id ])
    end

    it "writes no AuditLog row for a warehouse access change (existing behaviour)" do
      expect { update_employee(assigned_warehouse_ids: [ "", second_wh.id.to_s ]) }.not_to change(AuditLog, :count)
    end
  end

  describe "create" do
    # A phone number or an email is required ("Phone number or email must be present").
    def create_employee(attributes)
      post admin_users_path, params: { user: { first_name: "New", last_name: "Hire", email: "new.hire@example.com" }.merge(attributes) }
    end

    it "saves the assignments with the new employee" do
      expect { create_employee(assigned_warehouse_ids: [ "", main_wh.id.to_s ]) }.to change(User, :count).by(1)

      expect(response).to redirect_to(admin_users_path)
      expect(User.find_by!(first_name: "New").assigned_warehouses).to eq([ main_wh ])
    end

    it "saves neither the employee nor any assignment when the form is invalid (422)" do
      expect { create_employee(last_name: "", assigned_warehouse_ids: [ "", main_wh.id.to_s ]) }
        .not_to(change { [ User.count, WarehouseAssignment.count ] })

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "the form field" do
    it "renders one checkbox per business warehouse, checked for the assigned ones, plus the blank hidden value" do
      employee.assigned_warehouses << main_wh

      get edit_admin_user_path(employee)

      expect(response).to have_http_status(:ok)
      html = response.body
      expect(html).to include(%(<input type="hidden" name="user[assigned_warehouse_ids][]" value="" />))
      expect(html).to include(%(type="checkbox" value="#{main_wh.id}" checked="checked" name="user[assigned_warehouse_ids][]" id="user_assigned_warehouse_ids_#{main_wh.id}"))
      expect(html).to include(%(type="checkbox" value="#{second_wh.id}" name="user[assigned_warehouse_ids][]" id="user_assigned_warehouse_ids_#{second_wh.id}"))
      expect(html).not_to include(%(value="#{foreign_wh.id}" name="user[assigned_warehouse_ids][]"))
    end
  end
end
