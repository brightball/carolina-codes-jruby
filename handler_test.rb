# frozen_string_literal: true

# Drive shipped Sinatra handlers with a fake catalog (no Postgres).
# Structural reads of pre-commit + Gitea workflow live in the same script.

require "json"
require "socket"
require "stringio"
require "yaml"

FAILED = { n: 0 }
ROOT = File.expand_path(__dir__)

def expect(cond, msg)
  if cond
    warn "ok: #{msg}"
  else
    warn "FAIL: #{msg}"
    FAILED[:n] += 1
  end
end

# --- structural: pre-commit + Gitea jobs stay 1:1 with the five checks ---

CHECK_IDS = %w[tests sast audit gitleaks style].freeze

pc_path = File.join(ROOT, ".pre-commit-config.yaml")
expect(File.file?(pc_path), "pre-commit config exists")
pc_text = File.read(pc_path)
pc = YAML.safe_load(pc_text, permitted_classes: [Symbol]) || {}
hook_ids = Array(pc["repos"]).flat_map { |repo| Array(repo["hooks"]).map { |h| h["id"].to_s } }
CHECK_IDS.each do |id|
  expect(hook_ids.include?(id), "pre-commit hook id #{id}")
end
expect(hook_ids.include?("gitleaks"), "gitleaks invoked by that name in pre-commit")
expect(pc_text.match?(/\bSKIP=/), "pre-commit documents SKIP= escape")

wf_path = File.join(ROOT, ".gitea", "workflows", "precommit.yml")
expect(File.file?(wf_path), "Gitea workflow exists")
wf_text = File.read(wf_path)
expect(wf_text.include?("${{ github.token }}"), "workflow uses ${{ github.token }}")
expect(wf_text.include?("GITHUB_SHA"), "workflow clones GITHUB_SHA")
expect(wf_text.include?("x-access-token"), "workflow clones over HTTPS with x-access-token")
expect(wf_text.match?(/\bon:\s*\n(?:[ \t].*\n)*[ \t]*push:/) || wf_text.include?("push:"), "workflow runs on push")
expect(wf_text.include?("pull_request:"), "workflow runs on pull_request")

wf = YAML.safe_load(wf_text, permitted_classes: [Symbol]) || {}
jobs = wf["jobs"] || {}
PREPARE_ID = "prepare"
expect(jobs.key?(PREPARE_ID), "Gitea job #{PREPARE_ID}")
CHECK_IDS.each do |id|
  expect(jobs.key?(id), "Gitea job #{id}")
end
expect(jobs.keys.sort == (CHECK_IDS + [PREPARE_ID]).sort,
       "workflow jobs are prepare plus the five checks")

def job_runs(job)
  Array(job && job["steps"]).map { |step| step["run"].to_s }.join("\n")
end

def job_uses(job)
  Array(job && job["steps"]).map { |step| step["uses"].to_s }
end

def job_needs(job)
  needed = job && job["needs"]
  return [] if needed.nil?

  Array(needed).map(&:to_s)
end

needles = {
  "tests" => "handler_test.rb",
  "sast" => "semgrep",
  "audit" => "bundle-audit",
  "gitleaks" => "gitleaks",
  "style" => "rubocop"
}

prepare = jobs[PREPARE_ID]
prepare_runs = job_runs(prepare)
expect(job_needs(prepare).empty?, "Gitea job prepare has no needs")
expect(prepare_runs.include?("GITHUB_SHA"), "prepare clones GITHUB_SHA")
expect(prepare_runs.include?("x-access-token"), "prepare clones over HTTPS with x-access-token")
expect(prepare_runs.include?("git clone"), "prepare token-clones")
expect(prepare_runs.include?("bundle install"), "prepare runs bundle install")
expect(prepare_runs.include?("build-essential"),
       "prepare installs build-essential so prism can compile on jruby:10.0")
expect(prepare_runs.include?("semgrep"), "prepare installs semgrep into the workspace")
expect(prepare_runs.include?("gitleaks"), "prepare installs gitleaks into the workspace")
expect(job_uses(prepare).any? { |used| used.include?("actions/upload-artifact@v3") },
       "prepare uploads workspace artifact with upload-artifact@v3")
expect(prepare_runs.include?("prep-workspace"), "prepare packs prep-workspace")

needles.each do |id, needle|
  expect(job_runs(jobs[id]).include?(needle), "Gitea job #{id} runs #{needle}")
end
audit_steps = Array(jobs["audit"] && jobs["audit"]["steps"])
audit_apt = audit_steps.map { |step| step["run"].to_s }.select { |run| run.include?("apt-get") }
expect(audit_apt.any? { |run| run.match?(/\bgit\b/) },
       "Gitea job audit installs git so bundle-audit --update can clone ruby-advisory-db")
gitleaks_steps = Array(jobs["gitleaks"] && jobs["gitleaks"]["steps"])
gitleaks_apt = gitleaks_steps.map { |step| step["run"].to_s }.select { |run| run.include?("apt-get") }
expect(gitleaks_apt.any? { |run| run.match?(/\bgit\b/) },
       "Gitea job gitleaks installs git because gitleaks shells out to git")
expect(!job_runs(jobs["sast"]).include?("python3 -m semgrep"),
       "Gitea job sast invokes the semgrep launcher, not python3 -m semgrep")

CHECK_IDS.each do |id|
  job = jobs[id]
  runs = job_runs(job)
  uses = job_uses(job)
  expect(job_needs(job).include?(PREPARE_ID), "Gitea job #{id} needs #{PREPARE_ID}")
  expect(uses.any? { |used| used.include?("actions/download-artifact@v3") },
         "Gitea job #{id} restores workspace with download-artifact@v3")
  expect(!runs.include?("git clone"), "Gitea job #{id} does not clone")
  expect(!runs.include?("bundle install"), "Gitea job #{id} does not bundle install")
  expect(!runs.include?("build-essential"),
         "Gitea job #{id} does not reinstall build-essential")
  hits = needles.count { |_cid, needle| runs.include?(needle) }
  expect(hits == 1, "Gitea job #{id} is one check, not a combined all-checks command")
end

jobs.each do |name, job|
  uses = job_uses(job)
  expect(uses.none? { |used| used.include?("actions/checkout") }, "job #{name} does not use actions/checkout")
  expect(!job_runs(job).match?(/\bgit\s+init\b/), "job #{name} does not git init")
end

CHECK_IDS.each do |id|
  others = CHECK_IDS - [id]
  expect(!job_needs(jobs[id]).intersect?(others),
         "Gitea job #{id} stays concurrent with the other checks after prepare")
end
tests_run = job_runs(jobs["tests"])
expect(!tests_run.include?("java.specification.version"),
       "Gitea tests job does not require java.specification.version 27")
expect(!tests_run.include?("perf_test.rb"),
       "Gitea tests job executes handler_test.rb rather than the JDK 27 perf_test gate")
makefile = File.read(File.join(ROOT, "Makefile"))
expect(makefile.include?("handler_test.rb"), "make test runs handler_test.rb")
expect(!makefile.include?("perf_test.rb"), "make test does not run the JDK 27 perf_test gate")

self_src = File.read(__FILE__)
expect(self_src.include?('require_relative "app"'), "handler tests require the shipped app")
expect(self_src.include?("Sinatra::Application"), "handler tests hit Sinatra::Application")
expect(self_src.include?("Rack::MockRequest"), "handler tests use Rack::MockRequest")

# --- production pins (criterion 2): read the shipped boot files ---

def read_root(name)
  File.read(File.join(ROOT, name))
end

src = read_root("app.rb")
puma = read_root("config/puma.rb")
dockerfile = read_root("Dockerfile")
gemfile = read_root("Gemfile")
start = read_root("bin/start")
checkpoint = read_root("bin/crac_checkpoint.rb")
rackup = read_root("config.ru")
mise = read_root("mise.toml")
readme = read_root("README.md")
fly = read_root("fly.toml")

expect(src.include?('LISTEN_HOST = "::"'), "listen host is ::")
expect(!src.include?("0.0.0.0"), "Sinatra source does not bind 0.0.0.0")
expect(src.include?("set :bind, listen_bind"), "Sinatra uses listen_bind")
expect(puma.include?("tcp://[::]:"), "Puma config binds [::]")
expect(!puma.include?("0.0.0.0"), "Puma config is not IPv4-only")
expect(dockerfile.include?("jruby:10.0"), "Dockerfile uses JRuby 10.0 LTS")
expect(!dockerfile.include?("jruby:10.1"), "Dockerfile does not use JRuby 10.1")
expect(dockerfile.include?("ca-crac-jdk27") || dockerfile.include?("27-jdk-crac"),
       "production runtime JDK is JDK 27 CRaC")
expect(dockerfile.include?("jdk-crac") || dockerfile.include?("ca-crac"),
       "production image is a CRaC JDK")
expect(!dockerfile.include?("21-jdk-crac"), "Dockerfile runtime is not 21-jdk-crac")
expect(!mise.match?(/java\s*=\s*"21/), "mise does not pin Java 21")
expect(mise.match?(/^\s*java\s*=\s*"27(\.0(\.0)?)?"\s*$/), "mise pins Java 27")
expect(dockerfile.include?("CRaCEngine=warp"), "checkpoint JAVA_OPTS uses Warp")
expect(dockerfile.include?("CPUFeatures="), "checkpoint pins CPUFeatures")
expect(dockerfile.include?("--checkpoint"), "image build runs jruby --checkpoint")
expect(dockerfile.include?("--nocache"), "checkpoint passes --nocache")
expect(start.include?("--restore"), "start restores the CRaC snapshot")
expect(start.include?("--nocache"), "restore passes --nocache")
expect(start.include?("CRaCEngine=warp"), "restore JAVA_OPTS keeps Warp")
expect(start.include?("CRAC_RESTORE_JAVA_OPTS:--XX:CRaCEngine=warp"),
       "restore default JAVA_OPTS is Warp-only")
restore_default = start[/CRAC_RESTORE_JAVA_OPTS:-\\?-[^\n"]*/]
expect(!restore_default.nil?, "restore default JAVA_OPTS line is present")
if restore_default
  expect(!restore_default.include?("UseG1GC"), "restore does not re-pass UseG1GC")
  expect(!restore_default.include?("CPUFeatures"), "restore does not re-pass CPUFeatures")
  expect(!restore_default.include?("Xmx"), "restore does not re-pass heap flags")
  expect(!restore_default.include?("ActiveProcessorCount"), "restore does not re-pass CPU count")
end
expect(start.include?("cold-starting"), "start cold-starts Puma if CRaC restore fails")
expect(start.include?("puma") && start.include?("config.ru"), "cold start runs Puma via config.ru")
expect(checkpoint.include?('require_relative "../app"'), "checkpoint script loads the app")
expect(!checkpoint.include?("acquire_after_restore"), "checkpoint script does not acquire runtime I/O")
expect(!checkpoint.include?("register_with_elixir"), "checkpoint script does not register with the CMS")
expect(!checkpoint.include?("Sequel.connect"), "checkpoint script does not open a JDBC pool")
expect(!checkpoint.downcase.include?("puma"), "checkpoint script does not start Puma")
expect(!checkpoint.include?("TCPServer"), "checkpoint script does not bind a listen socket")
expect(rackup.include?("acquire_after_restore!"), "config.ru acquires DB/CMS after restore")
expect(!rackup.include?("TCPServer"), "config.ru does not bind the listen port")
expect(src.include?("def acquire_after_restore!"), "acquire_after_restore! exists")
expect(src.include?("def refresh_env_after_restore!"), "refresh_env_after_restore! exists")
expect(fly.match?(/min_machines_running\s*=\s*[1-9]\d*/),
       "Fly min_machines_running is at least 1")
expect(gemfile.include?('"puma", "~> 8.0"'), "Gemfile pins Puma 8")
expect(readme.match?(/JDK 27|Java 27/), "README documents JDK 27")
expect(readme.include?("CRaC"), "README documents CRaC production")
expect(!readme.include?("21-jdk-crac"), "README does not name 21-jdk-crac")

# --- handler tests: real routes, fake catalog ---

JRUBY_VERSION = "10.0.6.0" unless defined?(JRUBY_VERSION)

require "bundler/setup"
require "rack/mock"
require_relative "app"

# Counts catalog_db[:table] calls. A cached listing must not touch the catalog again.
CATALOG_READS = { n: 0 }

# In-memory Sequel-shaped catalog. Only the methods the shipped handlers call.
class FakeCatalog
  def initialize(tables)
    @tables = tables
  end

  def [](name)
    CATALOG_READS[:n] += 1
    FakeDataset.new(@tables.fetch(name.to_sym, []))
  end

  def execute(*_args)
    []
  end
end

class FakeDataset
  def initialize(rows)
    @rows = rows
  end

  def where(conds = {})
    FakeDataset.new(@rows.select { |row| row_matches?(row, conds) })
  end

  def order(*args)
    specs = args.map { |arg| order_spec(arg) }
    sorted = @rows.sort do |left, right|
      cmp = 0
      specs.each do |key, descending|
        cmp = compare_cells(cell(left, key), cell(right, key))
        cmp = -cmp if descending
        break unless cmp.zero?
      end
      cmp
    end
    FakeDataset.new(sorted)
  end

  def select(*cols)
    FakeDataset.new(@rows.map { |row| project(row, cols) })
  end

  def distinct
    FakeDataset.new(@rows.uniq)
  end

  def all
    @rows
  end

  def first
    @rows.first
  end

  def select_map(col)
    @rows.map { |row| cell(row, col) }
  end

  private

  def order_spec(arg)
    if defined?(Sequel::SQL::OrderedExpression) && arg.is_a?(Sequel::SQL::OrderedExpression)
      [arg.expression, arg.descending]
    else
      [arg, false]
    end
  end

  def compare_cells(left, right)
    return 0 if left == right
    return -1 if left.nil?
    return 1 if right.nil?

    left <=> right
  end

  def project(row, cols)
    cols.each_with_object({}) do |col, acc|
      key = col.is_a?(Symbol) ? col : col.to_s.to_sym
      acc[key] = cell(row, key)
    end
  end

  def cell(row, key)
    row[key] || row[key.to_s] || row[key.to_s.to_sym]
  end

  def row_matches?(row, conds)
    conds.all? do |key, value|
      actual = cell(row, key)
      expected = resolve(value)
      expected.is_a?(Array) ? expected.include?(actual) : actual == expected
    end
  end

  def resolve(value)
    return value unless value.respond_to?(:all) && !value.is_a?(String) && !value.is_a?(Array)

    value.all.map do |row|
      row[:speaker_slug] || row["speaker_slug"] || row[:slug] || row["slug"] || row.values.first
    end
  end
end

FAKE_TABLES = {
  v1_years: [
    { year: 2024 },
    { year: 2026 },
    { year: 2025 }
  ],
  v1_speakers: [
    {
      slug: "diana-pham",
      first_name: "Diana",
      last_name: "Pham",
      name: "Diana Pham",
      bio: "Speaker"
    },
    {
      slug: "no-talks-this-year",
      first_name: "Pat",
      last_name: "Silent",
      name: "Pat Silent",
      bio: "Past speaker"
    },
    {
      slug: "ada-lovelace",
      first_name: "Ada",
      last_name: "Lovelace",
      name: "Ada Lovelace",
      bio: "Speaker"
    },
    {
      slug: "grace-hopper",
      first_name: "Grace",
      last_name: "Hopper",
      name: "Grace Hopper",
      bio: "Speaker"
    }
  ],
  # Older years are listed first so a missing DESC order fails the contract.
  v1_talks: [
    {
      slug: "older-talk",
      title: "Older Talk",
      speaker_slug: "diana-pham",
      year: 2025,
      languages: "{elixir}",
      topics: "{otp}"
    },
    {
      slug: "old-only",
      title: "Old Only",
      speaker_slug: "no-talks-this-year",
      year: 2024,
      languages: "{ruby}",
      topics: "{testing}"
    },
    {
      slug: "ada-talk",
      title: "Analytical Engine",
      speaker_slug: "ada-lovelace",
      year: 2026,
      languages: "{ada}",
      topics: "{math}"
    },
    {
      slug: "grace-talk",
      title: "Compilers",
      speaker_slug: "grace-hopper",
      year: 2026,
      languages: "{cobol}",
      topics: "{compilers}"
    },
    {
      slug: "building-with-jruby",
      title: "Building with JRuby",
      speaker_slug: "diana-pham",
      year: 2026,
      languages: "{java,ruby}",
      topics: "{jvm,web}"
    }
  ],
  v1_sponsors: [
    { slug: "flywheel", name: "Flywheel" },
    { slug: "other-sponsor", name: "Other Sponsor" }
  ],
  v1_year_sponsors: [
    { slug: "flywheel", name: "Flywheel", year: 2026, tier: "platinum" }
  ],
  v1_sponsorships: [
    { sponsor_slug: "flywheel", year: 2025, tier: "gold" },
    { sponsor_slug: "flywheel", year: 2026, tier: "platinum" }
  ]
}.freeze

def install_fake_catalog
  CatalogCounters.reset!
  CATALOG_READS[:n] = 0
  CatalogCounters.connect_fn = -> { FakeCatalog.new(FAKE_TABLES) }
end

def http_get(path)
  Rack::MockRequest.new(Sinatra::Application).get(path)
end

def polyglot_header(res, name)
  res.get_header(name)
end

def expect_polyglot(res, label)
  expect(polyglot_header(res, "X-Polyglot-Language") == "JRuby", "#{label} sends the JRuby language header")
  expect(polyglot_header(res, "X-Polyglot-Framework") == "Sinatra", "#{label} sends the Sinatra framework header")
end

def years_descending?(years)
  list = Array(years)
  list.each_cons(2).all? { |left, right| left >= right }
end

SAVED_ENV = %w[DATABASE_URL CAROLINA_URL POLYGLOT_REGISTER_TOKEN PUBLIC_BASE_URL].to_h do |key|
  [key, ENV.fetch(key, nil)]
end

def restore_saved_env!
  SAVED_ENV.each do |key, value|
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end

def capture_stderr
  previous = $stderr
  buffer = StringIO.new
  $stderr = buffer
  yield
  buffer.string
ensure
  $stderr = previous
end

def with_silent_peer
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1]
  thread = Thread.new do
    loop do
      client = server.accept
      sleep 30
      client.close
    end
  rescue StandardError
    nil
  end
  yield port
ensure
  server&.close
  thread&.kill
  thread&.join(1)
end

def json_body(res)
  JSON.parse(res.body)
end

install_fake_catalog

expect(listen_host == "::", "listen_host helper is ::")
expect(["::", "[::]"].include?(Sinatra::Application.settings.bind), "Sinatra bind is IPv6")

health = http_get("/health")
expect(health.status == 200, "GET /health returns 200")
expect(json_body(health)["ok"] == true, "/health is JSON ok true")
expect(CATALOG_READS[:n].zero?, "/health does not read the catalog")
expect(CatalogCounters.connect_count.zero?, "/health does not open the catalog")
expect_polyglot(health, "GET /health")

root = http_get("/")
expect(root.status == 200, "GET / returns 200")
root_body = json_body(root)
expect(root_body["language"] == "JRuby", "/ names JRuby")
expect(root_body["framework"] == "Sinatra", "/ names Sinatra")
expect_polyglot(root, "GET /")
published_paths = [
  "/",
  "/health",
  "/v1/years",
  "/v1/speakers",
  "/v1/speakers/:slug",
  "/v1/speakers/:year/:slug",
  "/v1/sponsors",
  "/v1/sponsors/:slug",
  "/v1/sponsors/:year/:slug"
]
listed_paths = Array(root_body["endpoints"]).map { |row| row["path"] }
published_paths.each do |path|
  expect(listed_paths.include?(path), "/ lists #{path}")
end

years = http_get("/v1/years")
expect(years.status == 200, "GET /v1/years returns 200")
year_rows = json_body(years)["data"]
expect(year_rows.is_a?(Array), "years data is an array")
expect(year_rows.map { |row| row["year"] } == [2026, 2025, 2024], "GET /v1/years is descending")
expect_polyglot(years, "GET /v1/years")

all_speakers = http_get("/v1/speakers")
expect(all_speakers.status == 200, "GET /v1/speakers returns 200")
all_speaker_rows = json_body(all_speakers)["data"]
expect(all_speaker_rows.is_a?(Array), "unscoped speaker data is an array")
expect(all_speaker_rows.any? { |row| row["slug"] == "diana-pham" }, "unscoped speakers include diana-pham")
expect_polyglot(all_speakers, "GET /v1/speakers")

speaker_slug = http_get("/v1/speakers/diana-pham")
expect(speaker_slug.status == 200, "GET /v1/speakers/diana-pham returns 200")
speaker_slug_body = json_body(speaker_slug)["data"]
expect(speaker_slug_body.is_a?(Hash), "speaker slug data is an object")
expect(speaker_slug_body["slug"] == "diana-pham", "speaker slug matches")
expect(Array(speaker_slug_body["talks"]).size >= 2, "speaker slug includes talks")
expect(years_descending?(speaker_slug_body["years"]), "speaker slug years are descending")
expect_polyglot(speaker_slug, "GET /v1/speakers/:slug")

missing_slug = http_get("/v1/speakers/not-a-speaker")
expect(missing_slug.status == 404, "unknown speaker slug is 404")
expect(json_body(missing_slug)["error"] == "not_found", "unknown speaker slug error is not_found")
expect_polyglot(missing_slug, "GET /v1/speakers/:slug 404")

list = http_get("/v1/speakers?year=2026")
expect(list.status == 200, "GET /v1/speakers?year=2026 returns 200")
list_payload = json_body(list)
expect(list_payload.key?("data"), "speaker list has data")
speakers = list_payload["data"]
expect(speakers.is_a?(Array), "speaker list data is an array")
expect(speakers.size >= 3, "year-scoped speaker list covers multiple rows")
expect(speakers.none? { |row| row["slug"] == "no-talks-this-year" },
       "year-scoped speaker list omits a speaker with no talks that year")
diana = speakers.find { |row| row["slug"] == "diana-pham" }
expect(!diana.nil?, "year-scoped speaker list includes diana-pham")
%w[slug year years other_years talks languages topics].each do |key|
  expect(diana.key?(key), "year-scoped speaker list item has #{key}")
end
expect(diana["year"] == 2026, "year-scoped speaker list year is 2026")
expect(diana["years"] == [2026, 2025], "year-scoped speaker years are descending and include the other year")
expect(years_descending?(diana["years"]), "year-scoped speaker years are descending")
expect(diana["other_years"] == [2025], "year-scoped speaker other_years keeps the other year")
expect(diana["languages"] == %w[java ruby], "year-scoped speaker languages come from that year's talks")
expect(diana["topics"] == %w[jvm web], "year-scoped speaker topics come from that year's talks")
expect(Array(diana["talks"]).any? { |talk| talk["slug"] == "building-with-jruby" },
       "year-scoped speaker list talks are for 2026")
expect(Array(diana["talks"]).none? { |talk| talk["year"] == 2025 },
       "year-scoped speaker list omits other-year talks")
expect_polyglot(list, "GET /v1/speakers?year=2026")

detail = http_get("/v1/speakers/2026/diana-pham")
expect(detail.status == 200, "GET /v1/speakers/2026/diana-pham returns 200")
speaker = json_body(detail)["data"]
expect(speaker.is_a?(Hash), "speaker detail data is an object")
expect(speaker["slug"] == "diana-pham", "speaker detail slug")
expect(speaker["year"] == 2026, "speaker detail year")
%w[years other_years talks languages topics].each do |key|
  expect(speaker.key?(key), "speaker detail has #{key}")
end
expect(speaker["years"] == [2026, 2025], "speaker detail years are descending and include the other year")
expect(speaker["languages"] == %w[java ruby], "speaker detail languages")
expect(speaker["topics"] == %w[jvm web], "speaker detail topics")
expect(Array(speaker["talks"]).any? { |talk| talk["title"] == "Building with JRuby" },
       "speaker detail talks include the 2026 talk")
expect_polyglot(detail, "GET /v1/speakers/:year/:slug")

missing_speaker = http_get("/v1/speakers/2026/not-a-speaker")
expect(missing_speaker.status == 404, "unknown speaker detail is 404")
expect(json_body(missing_speaker)["error"] == "not_found", "unknown speaker error is not_found")
expect_polyglot(missing_speaker, "unknown year-scoped speaker")

no_year_talks = http_get("/v1/speakers/2026/no-talks-this-year")
expect(no_year_talks.status == 404, "speaker with no talks in year is 404")
expect(json_body(no_year_talks)["error"] == "not_found", "speaker with no talks in year error is not_found")

all_sponsors = http_get("/v1/sponsors")
expect(all_sponsors.status == 200, "GET /v1/sponsors returns 200")
expect(json_body(all_sponsors)["data"].any? { |row| row["slug"] == "flywheel" },
       "unscoped sponsors include flywheel")
expect_polyglot(all_sponsors, "GET /v1/sponsors")

sponsor_slug = http_get("/v1/sponsors/flywheel")
expect(sponsor_slug.status == 200, "GET /v1/sponsors/flywheel returns 200")
sponsor_slug_body = json_body(sponsor_slug)["data"]
expect(sponsor_slug_body["slug"] == "flywheel", "sponsor slug matches")
expect(Array(sponsor_slug_body["sponsorships"]).size >= 2, "sponsor slug includes sponsorships")
expect_polyglot(sponsor_slug, "GET /v1/sponsors/:slug")

missing_sponsor_slug = http_get("/v1/sponsors/not-a-sponsor")
expect(missing_sponsor_slug.status == 404, "unknown sponsor slug is 404")
expect(json_body(missing_sponsor_slug)["error"] == "not_found", "unknown sponsor slug error is not_found")

sponsors = http_get("/v1/sponsors?year=2026")
expect(sponsors.status == 200, "GET /v1/sponsors?year=2026 returns 200")
sponsor_rows = json_body(sponsors)["data"]
expect(sponsor_rows.is_a?(Array), "sponsor list data is an array")
flywheel = sponsor_rows.find { |row| row["slug"] == "flywheel" }
expect(!flywheel.nil?, "year-scoped sponsor list includes flywheel")
expect(flywheel["name"] == "Flywheel", "year-scoped sponsor list name")
expect(flywheel["year"] == 2026, "year-scoped sponsor list year")
expect_polyglot(sponsors, "GET /v1/sponsors?year=2026")

sponsor_detail = http_get("/v1/sponsors/2026/flywheel")
expect(sponsor_detail.status == 200, "GET /v1/sponsors/2026/flywheel returns 200")
sponsor = json_body(sponsor_detail)["data"]
expect(sponsor.is_a?(Hash), "sponsor detail data is an object")
expect(sponsor["slug"] == "flywheel", "sponsor detail slug")
%w[years other_years sponsorships].each do |key|
  expect(sponsor.key?(key), "sponsor detail has #{key}")
end
expect(sponsor["years"] == [2026, 2025], "sponsor detail years are descending and include the other year")
expect(years_descending?(sponsor["years"]), "sponsor detail years are descending")
expect(sponsor["other_years"] == [2025], "sponsor detail other_years keeps the other year")
expect(Array(sponsor["sponsorships"]).size >= 2, "sponsor detail sponsorships from catalog")
expect_polyglot(sponsor_detail, "GET /v1/sponsors/:year/:slug")

missing_sponsor = http_get("/v1/sponsors/2026/not-a-sponsor")
expect(missing_sponsor.status == 404, "unknown sponsor detail is 404")
expect(json_body(missing_sponsor)["error"] == "not_found", "unknown sponsor error is not_found")
expect_polyglot(missing_sponsor, "unknown year-scoped sponsor")

install_fake_catalog
first_speakers = http_get("/v1/speakers?year=2026")
speaker_rows = json_body(first_speakers)["data"]
speaker_reads = CATALOG_READS[:n]
expect(first_speakers.status == 200, "cache miss GET /v1/speakers?year=2026 returns 200")
expect(speaker_rows.size >= 3, "cache miss speaker listing has at least 3 rows")
expect(speaker_reads.positive? && speaker_reads <= 6,
       "first speaker listing stays a handful of catalog reads (reads=#{speaker_reads})")
expect(
  speaker_reads < (2 * speaker_rows.size),
  "first speaker listing does not grow about two catalog reads per row " \
  "(reads=#{speaker_reads} rows=#{speaker_rows.size})"
)
CATALOG_READS[:n] = 0
CatalogCounters.instance_variable_set(:@sql_count, 0)
second_speakers = http_get("/v1/speakers?year=2026")
expect(second_speakers.status == 200, "repeated GET /v1/speakers?year=2026 returns 200")
expect(second_speakers.body == first_speakers.body, "repeated speaker listing body matches")
expect(
  CATALOG_READS[:n].zero? && CatalogCounters.sql_count.zero?,
  "repeated GET /v1/speakers?year=2026 performs no further catalog reads " \
  "(reads=#{CATALOG_READS[:n]} sql=#{CatalogCounters.sql_count})"
)

CATALOG_READS[:n] = 0
CatalogCounters.instance_variable_set(:@sql_count, 0)
first_sponsors = http_get("/v1/sponsors?year=2026")
sponsor_reads = CATALOG_READS[:n]
expect(first_sponsors.status == 200, "cache miss GET /v1/sponsors?year=2026 returns 200")
expect(sponsor_reads.positive? && sponsor_reads <= 4,
       "first sponsor listing stays a handful of catalog reads (reads=#{sponsor_reads})")
CATALOG_READS[:n] = 0
CatalogCounters.instance_variable_set(:@sql_count, 0)
second_sponsors = http_get("/v1/sponsors?year=2026")
expect(second_sponsors.status == 200, "repeated GET /v1/sponsors?year=2026 returns 200")
expect(second_sponsors.body == first_sponsors.body, "repeated sponsor listing body matches")
expect(
  CATALOG_READS[:n].zero? && CatalogCounters.sql_count.zero?,
  "repeated GET /v1/sponsors?year=2026 performs no further catalog reads " \
  "(reads=#{CATALOG_READS[:n]} sql=#{CatalogCounters.sql_count})"
)

install_fake_catalog
seen_database_url = nil
CatalogCounters.connect_fn = lambda {
  seen_database_url = ENV.fetch("DATABASE_URL", nil)
  FakeCatalog.new(FAKE_TABLES)
}
posted = []
CatalogCounters.register_http_fn = lambda { |_uri, body|
  posted << body
  :ok
}
CatalogCounters.restore_env_fn = lambda {
  {
    "DATABASE_URL" => "postgres://probe-user:probe-pass@restore-db.example:6543/restore_db",
    "CAROLINA_URL" => "http://cms.example",
    "POLYGLOT_REGISTER_TOKEN" => "restore-token",
    "PUBLIC_BASE_URL" => "https://carolina-codes-jruby.fly.dev"
  }
}
ENV["DATABASE_URL"] = "postgres://old:old@127.0.0.1:5432/old"
acquire_after_restore!
expect(ENV["DATABASE_URL"] == "postgres://probe-user:probe-pass@restore-db.example:6543/restore_db",
       "acquire_after_restore! copies restore-time DATABASE_URL into ENV")
expect(seen_database_url == ENV["DATABASE_URL"],
       "restore-time DATABASE_URL is copied before the catalog URL is read")
restored_jdbc = jdbc_database_url
expect(restored_jdbc.include?("restore-db.example"), "jdbc_database_url sees the restore-time host")
expect(restored_jdbc.include?("probe-user"), "jdbc_database_url sees the restore-time user")
expect(restored_jdbc.include?("connectTimeout=#{CATALOG_CONNECT_TIMEOUT_SEC}"),
       "jdbc url sets connectTimeout")
expect(restored_jdbc.include?("socketTimeout=#{CATALOG_CONNECT_TIMEOUT_SEC}"),
       "jdbc url sets socketTimeout")
expect(!restored_jdbc.include?("127.0.0.1"), "jdbc_database_url is not the checkpoint fallback")
expect(CatalogCounters.register_attempt_count == 1, "registration is attempted when URL and token are present")
expect(CatalogCounters.register_skip_count.zero?, "registration is not skipped when URL and token are present")
expect(posted.size == 1 && posted.first.include?("JRuby"), "register payload names JRuby")
expect(posted.first.include?("Sinatra"), "register payload names Sinatra")
expect(posted.first.include?("carolina-codes-jruby.fly.dev"), "register payload uses restore-time PUBLIC_BASE_URL")

install_fake_catalog
CatalogCounters.restore_env_fn = lambda {
  {
    "DATABASE_URL" => "postgres://probe-user:probe-pass@restore-db.example:6543/restore_db",
    "CAROLINA_URL" => "http://cms.example"
  }
}
ENV.delete("POLYGLOT_REGISTER_TOKEN")
missing_token_log = capture_stderr { acquire_after_restore! }
expect(CatalogCounters.register_skip_count == 1, "registration is skipped when the token is missing")
expect(CatalogCounters.register_attempt_count.zero?, "a missing token is not a registration attempt")
expect(missing_token_log.include?("registration skipped"), "a missing token is logged")

install_fake_catalog
CatalogCounters.restore_env_fn = lambda {
  {
    "DATABASE_URL" => "postgres://probe-user:probe-pass@restore-db.example:6543/restore_db",
    "POLYGLOT_REGISTER_TOKEN" => "restore-token"
  }
}
ENV.delete("CAROLINA_URL")
missing_url_log = capture_stderr { acquire_after_restore! }
expect(CatalogCounters.register_skip_count == 1, "registration is skipped when the URL is missing")
expect(CatalogCounters.register_attempt_count.zero?, "a missing URL is not a registration attempt")
expect(missing_url_log.include?("registration skipped"), "a missing URL is logged")

install_fake_catalog
CatalogCounters.register_http_fn = nil
with_silent_peer do |port|
  CatalogCounters.restore_env_fn = lambda {
    {
      "DATABASE_URL" => "postgres://postgres:postgres@127.0.0.1:5432/carolina_dev",
      "CAROLINA_URL" => "http://127.0.0.1:#{port}",
      "POLYGLOT_REGISTER_TOKEN" => "dev-token"
    }
  }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  acquire_after_restore!
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  expect(elapsed < 5,
         "blackhole CMS acquire_after_restore! returns within a few seconds (#{format('%.2f', elapsed)}s)")
  expect(CatalogCounters.register_attempt_count == 1,
         "registration is still attempted when the CMS accepts and stays silent")
  expect(CatalogCounters.register_skip_count.zero?, "a silent CMS is not a skipped registration")
end

install_fake_catalog
CatalogCounters.connect_fn = nil
CatalogCounters.register_http_fn = nil
CatalogCounters.restore_env_fn = lambda {
  {
    "DATABASE_URL" => "postgres://postgres:postgres@192.0.2.1:5432/carolina_dev",
    "CAROLINA_URL" => "http://127.0.0.1:1",
    "POLYGLOT_REGISTER_TOKEN" => "dev-token"
  }
}
catalog_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
catalog_log = capture_stderr { acquire_after_restore! }
catalog_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - catalog_started
expect(
  catalog_elapsed < 5,
  "failed catalog connect acquire_after_restore! returns within a few seconds " \
  "(#{format('%.2f', catalog_elapsed)}s)"
)
expect(CatalogCounters.connect_count >= 1, "failed catalog connect was attempted")
expect($carolina_catalog_db.nil?, "failed catalog connect does not install a pool")
expect(CatalogCounters.register_attempt_count == 1,
       "registration is still attempted when catalog connect cannot succeed and does not require a live database")
expect(catalog_log.include?("catalog warmup failed"), "failed catalog connect is logged")

restore_saved_env!
CatalogCounters.reset!

if FAILED[:n].positive?
  warn "handler_test failed"
  exit 1
end
warn "handler_test passed"
