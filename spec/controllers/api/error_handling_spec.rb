require "rails_helper"

# Api::ErrorHandling — legacy vs standard modes, exercised through anonymous
# controllers so every exception class can be triggered directly.
RSpec.describe Api::ErrorHandling, type: :controller do
  include Devise::Test::ControllerHelpers

  let(:user) { create(:user) }

  def body = JSON.parse(response.body)

  shared_context "raising actions" do
    # The anonymous subclass takes its controller_path from the parent
    # ("api/v1/base"), so routes are drawn against that path.
    before do
      path = controller.controller_path
      routes.draw do
        %w[forbidden missing invalid param bad conflict boom ok].each do |action|
          get action, to: "#{path}##{action}"
        end
      end
    end
  end

  describe "standard contract" do
    controller(Api::V1::BaseController) do
      standard_api_contract!

      def forbidden = raise(Pundit::NotAuthorizedError)
      def missing   = raise(ActiveRecord::RecordNotFound)
      def param     = params.require(:thing)
      def bad       = raise(Api::Errors::BadRequest.new("Nope", details: [ { field: "x", code: "invalid", message: "Nope" } ]))
      def conflict  = raise(ActiveRecord::StaleObjectError)
      def boom      = raise("secret internal detail")
      def ok        = render_api_success({ a: 1 }, meta: { k: "v" })

      def invalid
        record = User.new
        record.validate
        raise ActiveRecord::RecordInvalid, record
      end
    end

    include_context "raising actions"

    context "when signed in" do
      before { sign_in user }

      {
        forbidden: [ 403, "forbidden" ],
        missing:   [ 404, "not_found" ],
        invalid:   [ 422, "validation_failed" ],
        param:     [ 400, "bad_request" ],
        bad:       [ 400, "bad_request" ],
        conflict:  [ 409, "conflict" ],
        boom:      [ 500, "internal_error" ]
      }.each do |action, (status, code)|
        it "maps #{action} to #{status} #{code} in the standard envelope" do
          get action
          expect(response.status).to eq(status)
          expect(body.keys).to match_array(%w[success error request_id message errors])
          expect(body["success"]).to be(false)
          expect(body["error"].keys).to match_array(%w[code message details])
          expect(body["error"]["code"]).to eq(code)
          expect(body["request_id"]).to eq(request.request_id)
        end
      end

      it "never renders internal exception details" do
        get :boom
        expect(response.body).not_to include("secret internal detail")
        expect(body["error"]["message"]).to eq(I18n.t("api.errors.internal_error"))
      end

      it "reports unexpected errors to Rails.error" do
        expect(Rails.error).to receive(:report).with(an_instance_of(RuntimeError), hash_including(handled: true))
        get :boom
      end

      it "renders field-level validation details" do
        get :invalid
        fields = body["error"]["details"].map { |d| d["field"] }
        expect(fields).to include("first_name")
        expect(body["error"]["details"].first.keys).to match_array(%w[field code message])
        expect(body["errors"]).to eq(body["error"]["details"].map { |d| d["message"] })
      end

      it "passes through BadRequest details" do
        get :bad
        expect(body["error"]["message"]).to eq("Nope")
        expect(body["error"]["details"]).to eq([ { "field" => "x", "code" => "invalid", "message" => "Nope" } ])
      end

      it "localizes messages" do
        I18n.with_locale(:ar) do
          user.update_column(:preferred_locale, "ar")
          get :forbidden
        end
        expect(body["error"]["message"]).to eq(I18n.t("api.errors.forbidden", locale: :ar))
      end

      it "renders success with meta and request_id" do
        get :ok
        expect(body).to eq("success" => true, "data" => { "a" => 1 }, "meta" => { "k" => "v" },
                           "request_id" => request.request_id)
      end
    end

    it "answers unauthenticated requests with the standard 401" do
      get :ok
      expect(response.status).to eq(401)
      expect(body["error"]["code"]).to eq("unauthenticated")
    end
  end

  describe "legacy contract (default)" do
    controller(Api::V1::BaseController) do
      def forbidden = raise(Pundit::NotAuthorizedError)
      def missing   = raise(ActiveRecord::RecordNotFound)
      def param     = params.require(:thing)
      def boom      = raise("legacy boom")
      def ok        = render_success({ a: 1 })
    end

    include_context "raising actions"
    before { sign_in user }

    it "keeps the legacy 403 body" do
      get :forbidden
      expect(response.status).to eq(403)
      expect(body).to eq("success" => false, "message" => "Forbidden", "errors" => [])
    end

    it "keeps the legacy 404 body" do
      get :missing
      expect(response.status).to eq(404)
      expect(body).to eq("success" => false, "message" => "Record not found", "errors" => [])
    end

    it "lets other exceptions propagate unchanged" do
      expect { get :boom }.to raise_error(RuntimeError, "legacy boom")
      expect { get :param }.to raise_error(ActionController::ParameterMissing)
    end

    it "keeps the legacy success envelope" do
      get :ok
      expect(body).to eq("success" => true, "data" => { "a" => 1 })
    end
  end
end
