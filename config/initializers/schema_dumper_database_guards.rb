# db/schema.rb cannot express PL/pgSQL functions or triggers, yet the test
# database (db:test:prepare in CI) and every fresh setup are built from it. The
# durable audit guards (R3.1, T-R31-14; db/migrate/20261108100000) would be
# silently missing there. This appends every user-defined function and trigger
# of the public schema to the dump, read back from PostgreSQL itself
# (pg_get_functiondef / pg_get_triggerdef), so schema.rb stays the single source.
# Functions owned by an extension are skipped. Output is sorted (deterministic).
module SchemaDumperDatabaseGuards
  private

  def trailer(stream)
    database_guards(stream)
    super
  end

  def database_guards(stream)
    functions = @connection.select_values(<<~SQL)
      SELECT pg_get_functiondef(p.oid)
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
      ORDER BY p.proname
    SQL
    triggers = @connection.select_values(<<~SQL)
      SELECT pg_get_triggerdef(t.oid)
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND NOT t.tgisinternal
      ORDER BY c.relname, t.tgname
    SQL
    return if functions.empty? && triggers.empty?

    stream.puts
    stream.puts "  # Functions and triggers (config/initializers/schema_dumper_database_guards.rb)."
    (functions + triggers.map { |definition| "#{definition};" }).each do |definition|
      stream.puts "  execute <<~'SQL'"
      definition.strip.each_line { |line| stream.puts "    #{line.rstrip}" }
      stream.puts "  SQL"
    end
  end
end

ActiveSupport.on_load(:active_record_postgresqladapter) do
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(SchemaDumperDatabaseGuards)
end
