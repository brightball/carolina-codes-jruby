# frozen_string_literal: true

require "json"

FAILED = { n: 0 }

def expect(cond, msg)
  if cond
    warn "ok: #{msg}"
  else
    warn "FAIL: #{msg}"
    FAILED[:n] += 1
  end
end

def assert_years_desc(speakers, label)
  found_multi = false
  speakers.each do |sp|
    years = Array(sp["years"] || sp[:years])
    next if years.size < 2

    found_multi = true
    years.each_cons(2) do |a, b|
      expect(a >= b, "#{label} years DESC for #{sp["slug"] || sp[:slug]}: #{years}")
    end
  end
  expect(found_multi, "#{label} expected a speaker with >=2 years")
end

src = File.read(File.expand_path("app.rb", __dir__))
puma = File.read(File.expand_path("config/puma.rb", __dir__))
dockerfile = File.read(File.expand_path("Dockerfile", __dir__))
gemfile = File.read(File.expand_path("Gemfile", __dir__))
start = File.read(File.expand_path("bin/start", __dir__))
checkpoint = File.read(File.expand_path("bin/crac_checkpoint.rb", __dir__))
rackup = File.read(File.expand_path("config.ru", __dir__))

expect(src.include?('LISTEN_HOST = "::"'), "listen host is ::")
expect(!src.include?('"0.0.0.0"'), "Sinatra source does not bind 0.0.0.0")
expect(src.include?("set :bind, listen_bind"), "Sinatra uses listen_bind")
expect(src.include?("sslmode=disable"), "JDBC keeps sslmode=disable")
expect(src.include?("ssl=false"), "JDBC keeps ssl=false")
expect(src.include?("max_connections: PUMA_THREADS"), "Sequel pool matches PUMA_THREADS")
expect(src.include?("respond_to?(:getArray)"), "pg_text_array accepts JDBC arrays")
expect(puma.include?("tcp://[::]:"), "Puma config binds [::]")
expect(!puma.include?("0.0.0.0"), "Puma config is not IPv4-only")
expect(puma.match?(/^\s*workers 0\s*$/), "Puma stays in single mode")
expect(puma.include?("PUMA_THREADS"), "Puma thread count is 2n+1 via PUMA_THREADS")
expect(gemfile.include?('"puma", "~> 8.0"'), "Gemfile pins Puma 8")
expect(!dockerfile.include?("-p 8080"), "Dockerfile does not use IPv4-only puma -p")
expect(start.include?("puma") && start.include?("config.ru"), "start uses Puma + config.ru (puma.rb bind)")
expect(dockerfile.include?("jruby:10.0"), "Dockerfile uses JRuby 10.0 LTS")
expect(!dockerfile.include?("jruby:10.1"), "Dockerfile does not use JRuby 10.1 tip")
expect(dockerfile.include?("RACK_ENV=production"), "Dockerfile sets RACK_ENV=production")
expect(dockerfile.include?("MaxRAMPercentage=55.0"), "Dockerfile sets container heap percentage")
expect(dockerfile.include?("ActiveProcessorCount=1"), "Dockerfile pins one JVM processor")
expect(!dockerfile.include?("--dev"), "Dockerfile does not enable jruby --dev")
expect(!start.include?("--dev"), "start does not enable jruby --dev")
expect(dockerfile.include?("jdk-crac"), "production image is a CRaC JDK")
expect(dockerfile.include?("CRaCEngine=warp"), "JAVA_OPTS uses Warp CRaC engine")
expect(dockerfile.include?("CPUFeatures="), "checkpoint pins CPUFeatures for Fly restore CPUs")
expect(dockerfile.include?("--checkpoint"), "image build runs jruby --checkpoint")
expect(dockerfile.include?(".jruby.checkpoint"), "pre-boot checkpoint dir is baked into the image")
expect(dockerfile.include?("bin/start") || dockerfile.include?("--restore"), "Dockerfile CMD is the CRaC restore start path")
expect(start.include?("--restore"), "start uses jruby --restore (CRaCRestoreFrom)")
expect(start.include?("--nocache"), "restore disables automatic AppCDS")
expect(dockerfile.include?("--nocache"), "checkpoint disables automatic AppCDS")
expect(start.include?("CRaCEngine=warp"), "restore JAVA_OPTS keeps Warp")
expect(start.include?("CRAC_RESTORE_JAVA_OPTS:--XX:CRaCEngine=warp"), "restore default JAVA_OPTS is Warp-only")
expect(start.include?("cold-starting"), "start cold-starts if CRaC restore fails")
expect(checkpoint.include?("require_relative \"../app\""), "checkpoint script loads the app")
expect(!checkpoint.include?("acquire_after_restore"), "checkpoint script does not acquire runtime I/O")
expect(!checkpoint.downcase.include?("puma"), "checkpoint script does not start Puma")
expect(!checkpoint.include?("TCPServer"), "checkpoint script does not bind a listen socket")
expect(src.include?("def catalog_db"), "catalog_db defers the JDBC pool")
expect(!src.match?(/^\s*DB\s*=\s*wrap_execute!/), "does not open the pool at load")
expect(!src.match?(/^register_with_elixir\s*$/), "does not register with the CMS at load")
expect(src.include?("def acquire_after_restore!"), "acquire_after_restore! exists")
expect(rackup.include?("acquire_after_restore!"), "config.ru acquires DB/CMS after restore")
expect(!rackup.include?("TCPServer"), "config.ru does not bind the listen port")

reg = src.index("def register_with_elixir")
expect(!reg.nil?, "register_with_elixir exists")
if reg
  acq = src.index("def acquire_after_restore!")
  fn = acq ? src[reg...acq] : src[reg..]
  expect(!fn.include?("open_pool"), "register-once does not open the pool")
  expect(!fn.include?("DB["), "register-once does not run catalog SQL")
  expect(!fn.include?("catalog_db"), "register-once does not open catalog_db")
  expect(!fn.include?("Sequel.connect"), "register-once does not open Sequel")
end

expect(src.include?("def refresh_env_after_restore!"), "refresh_env_after_restore! exists")
expect(src.include?("java.lang.System.getenv"), "restore env overlay reads System.getenv")
probe = File.read(File.expand_path("bin/crac_env_probe.rb", __dir__))
expect(probe.include?("acquire_after_restore!"), "env probe drives acquire_after_restore!")
expect(probe.include?("jdbc_database_url"), "env probe asserts jdbc_database_url")

acq = src.index("def acquire_after_restore!")
if acq
  body = src[acq..]
  expect(body.include?("refresh_env_after_restore!"), "after restore refreshes ENV before CMS/JDBC")
  expect(body.include?("register_with_elixir"), "after restore registers with CMS")
  expect(!body.include?("catalog_db"), "acquire_after_restore! does not open JDBC")
  expect(!body.include?("open_pool"), "acquire_after_restore! does not call open_pool")
  refresh_at = body.index("refresh_env_after_restore!")
  register_at = body.index("register_with_elixir")
  expect(!refresh_at.nil? && !register_at.nil? && refresh_at < register_at, "ENV refresh runs before CMS register")
end

if RUBY_ENGINE != "jruby"
  warn "skip JRuby runtime checks (RUBY_ENGINE=#{RUBY_ENGINE})"
  if FAILED[:n].positive?
    warn "perf_test failed"
    exit 1
  end
  warn "perf_test passed"
  exit 0
end

require "rack/mock"
require_relative "app"

jdbc_array = Object.new
def jdbc_array.getArray
  ["elixir", "java"]
end
expect(pg_text_array(jdbc_array) == ["elixir", "java"], "pg_text_array unwraps JDBC getArray")
expect(pg_text_array("{elixir,java}") == ["elixir", "java"], "pg_text_array still parses PG text arrays")

expect(listen_host == "::", "listen_host helper is ::")
expect(Sinatra::Application.settings.bind == "::" || Sinatra::Application.settings.bind == "[::]", "Sinatra bind is IPv6")

expect(CatalogCounters.connect_count == 0, "require app does not open the production DB pool")
expect($carolina_catalog_db.nil?, "require app does not assign the catalog pool")

saved_db_url = ENV["DATABASE_URL"]
saved_cms_url = ENV["CAROLINA_URL"]
saved_token = ENV["POLYGLOT_REGISTER_TOKEN"]
ENV.delete("DATABASE_URL")
ENV.delete("CAROLINA_URL")
ENV.delete("POLYGLOT_REGISTER_TOKEN")
checkpoint_jdbc = jdbc_database_url
expect(checkpoint_jdbc.include?("127.0.0.1"), "checkpoint identity JDBC falls back to 127.0.0.1")

restore_url = "postgres://probe-user:probe-pass@restore-db.example:6543/restore_db"
restore_cms = "http://127.0.0.1:1"
CatalogCounters.restore_env_fn = lambda {
  {
    "DATABASE_URL" => restore_url,
    "CAROLINA_URL" => restore_cms,
    "POLYGLOT_REGISTER_TOKEN" => "restore-token"
  }
}
acquire_after_restore!
expect(ENV["DATABASE_URL"] == restore_url, "acquire_after_restore! copies restore-time DATABASE_URL into ENV")
expect(ENV["CAROLINA_URL"] == restore_cms, "acquire_after_restore! copies restore-time CAROLINA_URL into ENV")
expect(ENV["POLYGLOT_REGISTER_TOKEN"] == "restore-token", "acquire_after_restore! copies restore-time register token into ENV")
restored_jdbc = jdbc_database_url
expect(restored_jdbc.include?("restore-db.example"), "jdbc_database_url sees restore-time host")
expect(restored_jdbc.include?("probe-user"), "jdbc_database_url sees restore-time user")
expect(!restored_jdbc.include?("127.0.0.1"), "jdbc_database_url is not the checkpoint fallback")
CatalogCounters.restore_env_fn = nil
ENV.delete("DATABASE_URL")
ENV.delete("CAROLINA_URL")
ENV.delete("POLYGLOT_REGISTER_TOKEN")
ENV["DATABASE_URL"] = saved_db_url unless saved_db_url.nil?
ENV["CAROLINA_URL"] = saved_cms_url unless saved_cms_url.nil?
ENV["POLYGLOT_REGISTER_TOKEN"] = saved_token unless saved_token.nil?

acquire_after_restore!
expect(CatalogCounters.connect_count == 0, "acquire_after_restore! does not open the catalog pool")
expect($carolina_catalog_db.nil?, "acquire_after_restore! does not assign the catalog pool")

stub_pool = Object.new
def stub_pool.execute(*)
  []
end
CatalogCounters.connect_fn = lambda { stub_pool }
catalog_db
expect(CatalogCounters.connect_count == 1, "catalog_db opens the pool on first use")
expect(!$carolina_catalog_db.nil?, "catalog_db assigns the catalog pool")
CatalogCounters.connect_fn = nil
CatalogCounters.reset!
expect(CatalogCounters.connect_count == 0, "reset clears the deferred pool")

boot_connects = CatalogCounters.connect_count
CatalogCounters.instance_variable_set(:@sql_count, 0)
health = Rack::MockRequest.new(Sinatra::Application).get("/health")
expect(health.status == 200, "/health returns 200")
expect(health.body.include?('"ok":true') || health.body.include?('"ok": true'), "/health body is ok JSON")
expect(CatalogCounters.sql_count == 0, "/health does not run SQL")
expect(CatalogCounters.connect_count == boot_connects, "/health does not open Postgres")

live = false
begin
  catalog_db
  live = true
rescue StandardError => e
  warn "catalog_db not live: #{e.class}: #{e.message}"
end
boot_connects = CatalogCounters.connect_count
CatalogCounters.instance_variable_set(:@sql_count, 0)
listing = Rack::MockRequest.new(Sinatra::Application).get("/v1/speakers?year=2026")
sql = CatalogCounters.sql_count
body = listing.body
data =
  begin
    JSON.parse(body)["data"]
  rescue StandardError
    []
  end
speakers = data.is_a?(Array) ? data.size : 0
warn "year list status=#{listing.status} sql=#{sql} speakers=#{speakers} connects=#{CatalogCounters.connect_count}"

if live && listing.status != 200
  expect(false, "live year listing status #{listing.status} body #{body[0, 400]}")
end

if listing.status == 200
  expect(speakers >= 3, "year listing returns N>=3 speakers")
  expect(sql.positive?, "listing runs SQL through shipped execute wrapper")
  expect(sql < (2 * speakers), "SQL count does not grow as ~2N")
  expect(sql <= 4, "year listing SQL is bounded (speakers + talks + years)")
  assert_years_desc(data, "handler")
  expect(CatalogCounters.connect_count == boot_connects, "listing reuses the deferred pool")

  rows = year_speakers(2026)
  assert_years_desc(rows, "year_speakers")

  CatalogCounters.instance_variable_set(:@sql_count, 0)
  listing2 = Rack::MockRequest.new(Sinatra::Application).get("/v1/speakers?year=2026")
  expect(listing2.status == 200, "second catalog request succeeds")
  expect(CatalogCounters.connect_count == boot_connects, "second catalog request reuses pool (no extra connect)")
else
  expect(sql < (2 * 3), "failed listing did not run per-row SQL for N=3")
end

if FAILED[:n].positive?
  warn "perf_test failed"
  exit 1
end
warn "perf_test passed"
