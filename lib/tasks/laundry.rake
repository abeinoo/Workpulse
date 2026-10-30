namespace :laundry do
  desc <<~DESC
    One-off setup for the Laundry Operations feature: marks a given Branch as
    branch_type: "laundry" and creates its Laundry Warehouse (a plain Warehouse
    row — Warehouse has no Branch dependency, so this is purely additive).

    Run manually once per business that has a central laundry — this is
    intentionally NOT a migration, since which Branch row is "the laundry"
    cannot be inferred from schema and must be confirmed explicitly.

    Usage:
      bin/rails "laundry:setup[BRANCH_ID]"
      bin/rails "laundry:setup[BRANCH_ID,Custom Warehouse Name]"

    Idempotent — safe to re-run; if the branch is already branch_type:
    "laundry" and a same-named warehouse already exists, both steps are
    skipped.
  DESC
  task :setup, [ :branch_id, :warehouse_name ] => :environment do |_t, args|
    branch = Branch.find(args[:branch_id])
    warehouse_name = args[:warehouse_name].presence || "Laundry Warehouse"

    if branch.branch_type_laundry?
      puts "Branch ##{branch.id} (#{branch.name}) is already branch_type: laundry."
    else
      branch.update!(branch_type: "laundry")
      puts "Branch ##{branch.id} (#{branch.name}) marked branch_type: laundry."
    end

    warehouse = branch.business.warehouses.find_by(name: warehouse_name)
    if warehouse
      puts "Warehouse '#{warehouse_name}' already exists (##{warehouse.id})."
    else
      warehouse = branch.business.warehouses.create!(name: warehouse_name)
      puts "Created Warehouse '#{warehouse_name}' (##{warehouse.id}) for business ##{branch.business_id}."
    end

    puts "Done. Next: create a TowelType (e.g. \"Bath Towel\") for business ##{branch.business_id} " \
         "and grant the laundry_operations permissions to the relevant PermissionRole(s)."
  end

  desc <<~DESC
    Development-only: resets every towel balance (clean/dirty/damaged/
    disposed/lost, at every branch, for every towel type, across every
    business) back to exactly zero, plus any in-transit (dispatched but not
    yet received) transfers — using ONLY the existing audited mechanisms:

      1. Laundry::TowelTransferCreator#cancel to unwind each dispatched
         transfer back to its source branch (this is the normal, audited
         "in transit" reversal — never a raw ledger edit).
      2. Laundry::TowelAdjuster to post the exact opposite adjustment for
         every remaining non-zero (branch, towel_type, status) balance,
         reason: "Development test balance reset".

    No ledger entries, adjustments, or transfers are deleted — every zeroing
    action is itself a new, audited row. No towel types, branches, users,
    permissions, payroll, attendance, inventory, or expense data is touched.

    Inactive branches are skipped (BUG-029): no adjustment is posted at one,
    and an in-transit transfer whose source is inactive is left as it is
    (cancelling it would post reversals at that branch). Their balances are
    listed as skipped instead.

    Runs entirely inside one DB transaction (all-or-nothing) and refuses to
    run outside the development environment.

    Usage: bin/rails laundry:reset_test_balances
  DESC
  task reset_test_balances: :environment do
    unless Rails.env.development?
      abort "Refusing to run: laundry:reset_test_balances only runs in the development " \
            "environment (current: #{Rails.env})."
    end

    reason = "Development test balance reset"
    before = Hash.new { |h, k| h[k] = {} }
    after  = Hash.new { |h, k| h[k] = {} }
    cancelled_transfer_ids = []
    skipped_transfer_ids   = []
    skipped_branches       = []
    adjustment_count = 0

    ActiveRecord::Base.transaction do
      Business.find_each do |business|
        next unless business.towel_types.exists?

        actor = business.owner || business.users.order(:id).first
        if actor.nil?
          puts "Skipping business ##{business.id} (#{business.name}) — no user to act as."
          next
        end

        business.towel_types.find_each do |towel_type|
          balances = Laundry::TowelBalances.new(towel_type)
          business.branches.active.find_each do |branch|
            before[[ business.id, towel_type.id ]][branch.id] = balances.by_status_for_branch(branch)
          end
        end

        # Step 1 — unwind every in-transit transfer for this business back to
        # its source branch. Must happen before the balance pass below, since
        # cancelling changes the source branch's balance.
        business.towel_transfers.dispatched.includes(:source_branch).find_each do |transfer|
          unless transfer.source_branch.active?
            skipped_transfer_ids << transfer.id
            next
          end

          result = Laundry::TowelTransferCreator.new(transfer).cancel(actor: actor, reason: reason)
          raise "Failed to cancel in-transit transfer ##{transfer.id}: #{result.error}" unless result.ok?

          cancelled_transfer_ids << transfer.id
        end

        # Step 2 — zero every remaining (branch, towel_type, status) balance.
        business.towel_types.find_each do |towel_type|
          balances = Laundry::TowelBalances.new(towel_type)

          business.branches.active.find_each do |branch|
            by_status = balances.by_status_for_branch(branch)

            TowelLedgerEntry::STATUSES.each do |status|
              current = by_status[status].to_d
              next if current.zero?

              result = Laundry::TowelAdjuster.new(actor: actor).call(
                towel_type: towel_type, branch: branch, status: status,
                adjustment_quantity: -current, reason: reason
              )
              raise "Failed to zero #{branch.name} / #{towel_type.name} / #{status}: #{result.error}" unless result.ok?

              adjustment_count += 1
            end

            after[[ business.id, towel_type.id ]][branch.id] = balances.by_status_for_branch(branch)
          end
        end

        skipped_branches.concat(business.branches.where(active: false).map { |branch| "#{business.name} / #{branch.name}" })
      end
    end

    puts "== Before -> After (only non-zero-before rows shown) =="
    before.each do |(business_id, towel_type_id), by_branch|
      business   = Business.find(business_id)
      towel_type = TowelType.find(towel_type_id)
      by_branch.each do |branch_id, before_status|
        next if before_status.values.all? { |v| v.to_d.zero? }

        branch = Branch.find(branch_id)
        after_status = after[[ business_id, towel_type_id ]][branch_id]
        puts "  [#{business.name}] #{branch.name} / #{towel_type.name}"
        puts "    before: #{before_status}"
        puts "    after:  #{after_status}"
      end
    end

    puts "\nCancelled #{cancelled_transfer_ids.size} in-transit transfer(s): #{cancelled_transfer_ids}"
    puts "Skipped #{skipped_transfer_ids.size} in-transit transfer(s) from inactive branches: #{skipped_transfer_ids}"
    puts "Skipped inactive branch(es): #{skipped_branches.join(', ').presence || 'none'}"
    puts "Posted #{adjustment_count} balancing adjustment(s), reason: \"#{reason}\"."
    puts "Done."
  end
end
