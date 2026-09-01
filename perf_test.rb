# frozen_string_literal: true

require "json"
require "rack/mock"

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

expect(src.include?('LISTEN_HOST = "::"'), "listen host is ::")
expect(!src.include?('"0.0.0.0"'), "Sinatra source does not bind 0.0.0.0")
expect(src.include?("set :bind, listen_bind"), "Sinatra uses listen_bind")
expect(src.include?("sslmode=disable"), "JDBC keeps sslmode=disable")
expect(src.include?("ssl=false"), "JDBC keeps ssl=false")
expect(puma.include?("tcp://[::]:"), "Puma config binds [::]")
expect(!puma.include?("0.0.0.0"), "Puma config is not IPv4-only")
expect(!dockerfile.include?("-p 8080"), "Dockerfile does not use IPv4-only puma -p")
expect(dockerfile.include?("puma") && dockerfile.include?("config.ru"), "Dockerfile uses Puma + config.ru (puma.rb bind)")

reg = src.index("def register_with_elixir")
expect(!reg.nil?, "register_with_elixir exists")
if reg
  fn = src[reg..]
  expect(!fn.include?("open_pool"), "register-once does not open the pool")
  expect(!fn.include?("DB["), "register-once does not run catalog SQL")
  expect(!fn.include?("Sequel.connect"), "register-once does not open Sequel")
end

require_relative "app"

expect(listen_host == "::", "listen_host helper is ::")
expect(Sinatra::Application.settings.bind == "::" || Sinatra::Application.settings.bind == "[::]", "Sinatra bind is IPv6")

boot_connects = CatalogCounters.connect_count
CatalogCounters.instance_variable_set(:@sql_count, 0)
health = Rack::MockRequest.new(Sinatra::Application).get("/health")
expect(health.status == 200, "/health returns 200")
expect(health.body.include?('"ok":true') || health.body.include?('"ok": true'), "/health body is ok JSON")
expect(CatalogCounters.sql_count == 0, "/health does not run SQL")
expect(CatalogCounters.connect_count == boot_connects, "/health does not open Postgres")

live = !DB.nil?
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
  expect(CatalogCounters.connect_count == boot_connects, "listing reuses the boot pool")

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
