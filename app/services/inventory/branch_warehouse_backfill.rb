module Inventory
  # Warehouse Architecture — PR 4: gives EXISTING sales branches their branch
  # warehouse ("<Branch Name> – المخزن", kind "branch", empty). New and
  # newly-sales branches are provisioned by the branch lifecycle
  # (OrganizationAccess::BranchProvisioning); this is the one-off remediation
  # for branches that predate it, run by an operator through
  # `bin/rails inventory:branch_warehouse_backfill` (dry run unless EXECUTE=1).
  #
  # Bound to an actor, who must be active and manage branches (BranchPolicy;
  # owners implicitly). Everything is limited to the actor's own business —
  # no other business's branches are planned, shown or reachable.
  #
  #   plan    — read-only: classifies every branch of the actor's business
  #             (READY, ALREADY_PROVISIONED, NAME_COLLISION, INCONSISTENT_STATE,
  #             NOT_ELIGIBLE, REQUIRES_MANUAL_REVIEW). Writes nothing, ever.
  #             A business not in approved_business_ids, and an inactive sales
  #             branch, are REQUIRES_MANUAL_REVIEW.
  #   execute — provisions only the explicitly listed branches, each in its
  #             OWN transaction, re-classified under its business -> branch
  #             row locks (the lock order of every branch lifecycle service) so
  #             nothing can change between the check and the write. Refused
  #             outright — every listed branch FAILED, nothing written — when a
  #             transaction is already open (each branch would only be a
  #             savepoint of it, not independent) or the actor is inactive.
  #             Creation goes through Inventory::BranchWarehouseProvisioning —
  #             the existing provisioning path (WarehouseManager's locking, name
  #             lock, idempotency and fail-closed audit), with audit source
  #             "branch_backfill". A refused or failed branch rolls back only
  #             itself and is reported FAILED with the reason; the run
  #             continues. Nothing is skipped silently.
  #
  # Never touched: existing warehouses (an unclassified warehouse stays
  # unclassified, a central one stays central), stock, movements, documents.
  class BranchWarehouseBackfill
    SOURCE = "branch_backfill".freeze
    LOCK   = "FOR NO KEY UPDATE".freeze

    # Raised by #plan when the actor may not see this business's branches.
    class Refused < StandardError; end

    Candidate = Struct.new(:business_id, :business_name, :branch_id, :branch_name, :branch_type, :active,
                           :existing_warehouse_id, :proposed_name, :name_taken_by_id, :status, :reason,
                           keyword_init: true)

    Outcome = Struct.new(:branch_id, :status, :warehouse_id, :reason, keyword_init: true) do
      def failed? = status == "FAILED"
    end

    def self.classify(branch, approved:)
      proposed = WarehouseManager.branch_warehouse_name(branch)
      attributes = { business_id: branch.business_id, business_name: branch.business.name, branch_id: branch.id,
                     branch_name: branch.name, branch_type: branch.branch_type, active: branch.active,
                     proposed_name: proposed }
      verdict = lambda { |status, reason, **extra| Candidate.new(**attributes.merge(extra), status: status, reason: reason) }

      return verdict.call("NOT_ELIGIBLE", "not a sales branch (#{branch.branch_type})", proposed_name: nil) unless branch.branch_type_sales?

      existing = Warehouse.find_by(branch_id: branch.id)
      if existing
        valid = existing.kind_branch? && existing.business_id == branch.business_id
        return verdict.call(valid ? "ALREADY_PROVISIONED" : "INCONSISTENT_STATE",
                            valid ? "branch warehouse ##{existing.id} exists" : "linked warehouse ##{existing.id} is not a valid branch warehouse",
                            existing_warehouse_id: existing.id)
      end

      return verdict.call("REQUIRES_MANUAL_REVIEW", "business not approved for this backfill") unless approved
      return verdict.call("REQUIRES_MANUAL_REVIEW", "inactive sales branch") unless branch.active?

      taken = Warehouse.where(business_id: branch.business_id).where("LOWER(name) = LOWER(?)", proposed).pick(:id)
      return verdict.call("NAME_COLLISION", "warehouse ##{taken} already has the name", name_taken_by_id: taken) if taken

      verdict.call("READY", "no warehouse yet; a new, empty branch warehouse will be created")
    end

    def initialize(actor:, approved_business_ids:)
      @actor    = actor
      @approved = approved_business_ids.map { |id| Integer(id) }
    end

    # Read-only classification of every branch of the actor's business.
    def plan
      refusal = actor_refusal
      raise Refused, I18n.t("inventory.warehouses.backfill.errors.#{refusal}") if refusal

      Branch.where(business_id: @actor.business_id).includes(:business).order(:id)
            .map { |branch| self.class.classify(branch, approved: approved?(branch.business_id)) }
    end

    # One Outcome per listed branch id, in order.
    def execute(branch_ids:)
      ids = branch_ids.map { |id| Integer(id) }.uniq
      refusal = run_refusal
      return ids.map { |id| failed(id, I18n.t("inventory.warehouses.backfill.errors.#{refusal}")) } if refusal

      ids.map { |id| execute_one(id) }
    end

    private

    def approved?(business_id) = @approved.include?(business_id)

    # Checked before any branch: each branch must get its own transaction, and
    # an inactive actor may not provision (nor be named by the audit entries).
    def run_refusal
      return :transaction_open if Warehouse.connection.transaction_open?
      return :inactive_actor unless @actor.active?

      nil
    end

    # nil when the actor may see the business's branches.
    def actor_refusal
      return :inactive_actor unless @actor.active?
      return :not_authorized unless BranchPolicy.new(@actor, Branch).index?

      nil
    end

    def execute_one(branch_id)
      Warehouse.transaction do
        Business.where(id: @actor.business_id).lock(LOCK).pick(:id)
        branch = Branch.where(business_id: @actor.business_id).lock(LOCK).find_by(id: branch_id)
        next failed(branch_id, "branch not found in the actor's business") unless branch
        next failed(branch_id, "not authorized (manage_branches)") unless BranchPolicy.new(@actor, branch).update?

        candidate = self.class.classify(branch, approved: approved?(branch.business_id))
        case candidate.status
        when "ALREADY_PROVISIONED"
          Outcome.new(branch_id: branch_id, status: "ALREADY_PROVISIONED", warehouse_id: candidate.existing_warehouse_id,
                      reason: candidate.reason)
        when "READY"
          warehouse = BranchWarehouseProvisioning.provision!(branch: branch, actor: @actor, source: SOURCE)
          Outcome.new(branch_id: branch_id, status: "CREATED", warehouse_id: warehouse.id, reason: candidate.proposed_name)
        else
          failed(branch_id, "#{candidate.status}: #{candidate.reason}")
        end
      end
    rescue OrganizationAccess::BranchProvisioning::Failed => e
      failed(branch_id, e.message)
    rescue ActiveRecord::ActiveRecordError => e
      failed(branch_id, "#{e.class}: #{e.message}")
    end

    def failed(branch_id, reason) = Outcome.new(branch_id: branch_id, status: "FAILED", reason: reason)
  end
end
