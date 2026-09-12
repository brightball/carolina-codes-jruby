# frozen_string_literal: true

require "sinatra"
require "json"
require "sequel"
require "net/http"
require "uri"

LISTEN_HOST = "::"
PUMA_THREADS = Integer(ENV.fetch("PUMA_THREADS", "3"))

module CatalogCounters
  class << self
    attr_accessor :connect_fn, :query_fn, :restore_env_fn, :register_http_fn

    def sql_count
      @sql_count || 0
    end

    def connect_count
      @connect_count || 0
    end

    def inc_sql
      @sql_count = sql_count + 1
    end

    def inc_connect
      @connect_count = connect_count + 1
    end

    def register_attempt_count
      @register_attempt_count || 0
    end

    def register_skip_count
      @register_skip_count || 0
    end

    def inc_register_attempt
      @register_attempt_count = register_attempt_count + 1
    end

    def inc_register_skip
      @register_skip_count = register_skip_count + 1
    end

    def reset!
      @sql_count = 0
      @connect_count = 0
      @register_attempt_count = 0
      @register_skip_count = 0
      $carolina_catalog_db = nil
      $carolina_listing_cache = nil
      self.restore_env_fn = nil
      self.register_http_fn = nil
    end
  end
end

CatalogCounters.reset!

def jdbc_database_url
  url = ENV.fetch("DATABASE_URL", "postgres://postgres:postgres@127.0.0.1:5432/carolina_dev")
  return url if url.start_with?("jdbc:")

  uri = URI.parse(url)
  user = uri.user
  pass = uri.password
  host = uri.host || "127.0.0.1"
  port = uri.port || 5432
  db = (uri.path || "/carolina_dev").delete_prefix("/")
  jdbc = "jdbc:postgresql://#{host}:#{port}/#{db}"
  params = []
  params << "user=#{user}" if user
  params << "password=#{pass}" if pass && user
  params << "ssl=false"
  params << "sslmode=disable"
  jdbc += "?#{params.join("&")}"
  jdbc
end

def listen_host
  LISTEN_HOST
end

def listen_bind
  LISTEN_HOST
end

def wrap_execute!(database)
  return database if database.nil?
  return database if database.singleton_methods.include?(:__carolina_execute)

  database.define_singleton_method(:__carolina_execute, database.method(:execute))
  database.define_singleton_method(:execute) do |*args, &block|
    CatalogCounters.inc_sql
    if CatalogCounters.query_fn
      CatalogCounters.query_fn.call(*args, &block)
    else
      __carolina_execute(*args, &block)
    end
  end
  database
end

def open_pool
  CatalogCounters.inc_connect
  return CatalogCounters.connect_fn.call if CatalogCounters.connect_fn

  Sequel.connect(jdbc_database_url, max_connections: PUMA_THREADS)
end

# CRaC checkpoint must not freeze a JDBC pool. Open after restore (config.ru)
# or lazily on the first catalog request.
CATALOG_DB_MUTEX = Mutex.new

def catalog_db
  return $carolina_catalog_db if $carolina_catalog_db

  CATALOG_DB_MUTEX.synchronize do
    $carolina_catalog_db ||= wrap_execute!(open_pool)
  end
end

LANGUAGE = "JRuby"
LANGUAGE_VERSION = JRUBY_VERSION
API_VERSION = "0.2.0"
FRAMEWORK = "Sinatra"
CREATED_YEAR = 2026
SCHEMA_VERSION = 1

ENDPOINTS = [
  { "method" => "GET", "path" => "/", "query" => [] },
  { "method" => "GET", "path" => "/health", "query" => [] },
  { "method" => "GET", "path" => "/v1/years", "query" => [] },
  { "method" => "GET", "path" => "/v1/speakers", "query" => ["year"] },
  { "method" => "GET", "path" => "/v1/speakers/:slug", "query" => [] },
  { "method" => "GET", "path" => "/v1/speakers/:year/:slug", "query" => [] },
  { "method" => "GET", "path" => "/v1/sponsors", "query" => ["year"] },
  { "method" => "GET", "path" => "/v1/sponsors/:slug", "query" => [] },
  { "method" => "GET", "path" => "/v1/sponsors/:year/:slug", "query" => [] }
].freeze

set :bind, listen_bind
set :port, Integer(ENV.fetch("PORT", "4003"))
disable :protection
# Empty list allows all Host headers (Fly *.fly.dev + internal checks).
set :host_authorization, permitted_hosts: []
if ENV["RACK_ENV"] == "production"
  disable :logging
  disable :dump_errors
  disable :show_exceptions
end

before do
  content_type :json
  headers "X-Polyglot-Language" => LANGUAGE, "X-Polyglot-Framework" => FRAMEWORK
end

get "/" do
  JSON.generate(
    language: LANGUAGE,
    language_version: LANGUAGE_VERSION,
    api_version: API_VERSION,
    framework: FRAMEWORK,
    created_year: CREATED_YEAR,
    schema_version: SCHEMA_VERSION,
    endpoints: ENDPOINTS
  )
end

get "/health" do
  JSON.generate(ok: true)
end

get "/v1/years" do
  rows = catalog_db[:v1_years].order(Sequel.desc(:year)).all
  JSON.generate(data: rows.map { |r| stringify_keys(r) })
end

get "/v1/speakers" do
  if params["year"]
    year = Integer(params["year"])
    cached_listing("speakers:#{year}") { JSON.generate(data: year_speakers(year)) }
  else
    dataset = catalog_db[:v1_speakers].order(:last_name, :first_name)
    JSON.generate(data: dataset.all.map { |r| stringify_keys(r) })
  end
end

get %r{/v1/speakers/(\d{4})/([^/]+)} do |year, slug|
  year = Integer(year)
  speaker = catalog_db[:v1_speakers].where(slug: slug).first
  halt 404, JSON.generate(error: "not_found") unless speaker

  payload = speaker_with_year(speaker, year)
  halt 404, JSON.generate(error: "not_found") if payload["talks"].empty?
  JSON.generate(data: payload)
end

get "/v1/speakers/:slug" do
  speaker = catalog_db[:v1_speakers].where(slug: params["slug"]).first
  halt 404, JSON.generate(error: "not_found") unless speaker

  talks = catalog_db[:v1_talks].where(speaker_slug: params["slug"]).all
  years = talks.map { |t| t[:year] || t["year"] }.uniq.sort.reverse
  payload = stringify_keys(speaker).merge(
    "years" => years,
    "talks" => talks.map { |t| stringify_keys(t) }
  )
  JSON.generate(data: payload)
end

get "/v1/sponsors" do
  if params["year"]
    year = Integer(params["year"])
    cached_listing("sponsors:#{year}") do
      rows = catalog_db[:v1_year_sponsors].where(year: year).order(:name).all
      JSON.generate(data: rows.map { |r| stringify_keys(r) })
    end
  else
    dataset = catalog_db[:v1_sponsors].order(:name)
    JSON.generate(data: dataset.all.map { |r| stringify_keys(r) })
  end
end

get %r{/v1/sponsors/(\d{4})/([^/]+)} do |year, slug|
  year = Integer(year)
  row = catalog_db[:v1_year_sponsors].where(year: year, slug: slug).first
  halt 404, JSON.generate(error: "not_found") unless row

  years = catalog_db[:v1_sponsorships].where(sponsor_slug: slug).select_map(:year).uniq.sort.reverse
  payload = stringify_keys(row).merge(
    "years" => years,
    "other_years" => years.reject { |y| y == year },
    "sponsorships" => catalog_db[:v1_sponsorships].where(sponsor_slug: slug).all.map { |s| stringify_keys(s) }
  )
  JSON.generate(data: payload)
end

get "/v1/sponsors/:slug" do
  sponsor = catalog_db[:v1_sponsors].where(slug: params["slug"]).first
  halt 404, JSON.generate(error: "not_found") unless sponsor

  sponsorships = catalog_db[:v1_sponsorships].where(sponsor_slug: params["slug"]).all
  payload = stringify_keys(sponsor).merge("sponsorships" => sponsorships.map { |s| stringify_keys(s) })
  JSON.generate(data: payload)
end

def year_speakers(year)
  speakers = catalog_db[:v1_speakers]
    .where(slug: catalog_db[:v1_talks].where(year: year).select(:speaker_slug))
    .order(:last_name, :first_name)
    .all
  attach_year_tags(speakers, year)
end

def attach_year_tags(speakers, year)
  return [] if speakers.empty?

  slugs = speakers.map { |speaker| speaker[:slug] || speaker["slug"] }
  talks_by = load_talks_for_year(year)
  years_by = load_years_for_slugs(slugs)
  speakers.map do |speaker|
    slug = speaker[:slug] || speaker["slug"]
    talks = Array(talks_by[slug]).map { |talk| stringify_keys(talk) }
    years = Array(years_by[slug])
    stringify_keys(speaker).merge(
      "year" => year,
      "years" => years,
      "other_years" => years.reject { |y| y == year },
      "talks" => talks,
      "languages" => unique_tags(talks, "languages"),
      "topics" => unique_tags(talks, "topics")
    )
  end
end

def load_talks_for_year(year)
  catalog_db[:v1_talks].where(year: year).order(:speaker_slug, Sequel.desc(:year)).all
    .group_by { |talk| talk[:speaker_slug] || talk["speaker_slug"] }
end

def load_years_for_slugs(slugs)
  return {} if slugs.empty?

  rows = catalog_db[:v1_talks]
    .where(speaker_slug: slugs)
    .select(:speaker_slug, :year)
    .distinct
    .order(:speaker_slug, Sequel.desc(:year))
    .all
  grouped = {}
  rows.each do |row|
    slug = row[:speaker_slug] || row["speaker_slug"]
    year = row[:year] || row["year"]
    (grouped[slug] ||= []) << year
  end
  grouped
end

def speaker_with_year(speaker, year)
  slug = speaker[:slug] || speaker["slug"]
  talks = catalog_db[:v1_talks].where(speaker_slug: slug, year: year).all.map { |t| stringify_keys(t) }
  years = catalog_db[:v1_talks].where(speaker_slug: slug).select_map(:year).uniq.sort.reverse
  stringify_keys(speaker).merge(
    "year" => year,
    "years" => years,
    "other_years" => years.reject { |y| y == year },
    "talks" => talks,
    "languages" => unique_tags(talks, "languages"),
    "topics" => unique_tags(talks, "topics")
  )
end

def unique_tags(talks, key)
  talks.flat_map { |talk| pg_text_array(talk[key]) }.uniq
end

def pg_text_array(value)
  return [] if value.nil?

  if value.respond_to?(:getArray)
    begin
      value = value.getArray
    rescue StandardError
      # Fall through to string / Array handling.
    end
  end

  case value
  when Array
    value.map(&:to_s).reject(&:empty?)
  when String
    stripped = value.strip
    return [] if stripped.empty? || stripped == "{}"
    inner = stripped.start_with?("{") && stripped.end_with?("}") ? stripped[1..-2] : stripped
    inner.split(",").map { |part| part.gsub(/\A"|"\z/, "").strip }.reject(&:empty?)
  else
    Array(value).map(&:to_s).reject(&:empty?)
  end
end

def stringify_keys(row)
  row.each_with_object({}) do |(key, value), acc|
    name = key.to_s
    acc[name] = %w[languages topics].include?(name) ? pg_text_array(value) : value
  end
end

def register_with_elixir
  url = ENV["CAROLINA_URL"]
  token = ENV["POLYGLOT_REGISTER_TOKEN"]
  if url.nil? || url.empty? || token.nil? || token.empty?
    CatalogCounters.inc_register_skip
    warn "registration skipped: missing CAROLINA_URL or POLYGLOT_REGISTER_TOKEN"
    return :skipped
  end

  CatalogCounters.inc_register_attempt
  uri = URI.join(url.end_with?("/") ? url : "#{url}/", "internal/api-endpoints/register")
  body = {
    language: LANGUAGE,
    language_version: LANGUAGE_VERSION,
    api_version: API_VERSION,
    framework: FRAMEWORK,
    created_year: CREATED_YEAR,
    schema_version: SCHEMA_VERSION,
    base_url: ENV.fetch("PUBLIC_BASE_URL", "http://127.0.0.1:#{settings.port}"),
    endpoints: ENDPOINTS
  }

  if CatalogCounters.register_http_fn
    return CatalogCounters.register_http_fn.call(uri, JSON.generate(body))
  end

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{token}"
  req["Content-Type"] = "application/json"
  req.body = JSON.generate(body)
  res = http.request(req)
  warn "registered with CMS status=#{res.code} base_url=#{body[:base_url]}"
  res
rescue StandardError => e
  warn "registration failed: #{e.message}"
end

# CRaC restore keeps JRuby's ENV at checkpoint values. Azul copies the
# restore-time container env into java.lang.System.getenv. Overlay that
# onto ENV before reading DATABASE_URL / CMS secrets.
def crac_restore_env_map
  if CatalogCounters.restore_env_fn
    CatalogCounters.restore_env_fn.call
  elsif RUBY_ENGINE == "jruby"
    java.lang.System.getenv
  end
end

def refresh_env_after_restore!
  map = crac_restore_env_map
  return if map.nil?

  map.each do |key, value|
    next if value.nil?
    ENV[key.to_s] = value.to_s
  end
end

LISTING_CACHE_TTL_SEC = 30
LISTING_CACHE_MUTEX = Mutex.new

def listing_cache
  $carolina_listing_cache ||= {}
end

def cached_listing(key)
  now = Time.now.to_f
  LISTING_CACHE_MUTEX.synchronize do
    hit = listing_cache[key]
    return hit[:json] if hit && (now - hit[:at]) < LISTING_CACHE_TTL_SEC
  end
  json = yield
  LISTING_CACHE_MUTEX.synchronize do
    listing_cache[key] = { json: json, at: Time.now.to_f }
  end
  json
end

def warmup_years
  [2026, Integer(Time.now.year)].uniq
end

# Prime JDBC + year listings so CMS's ~200ms polyglot timeout hits cached JSON.
def warmup_catalog!
  catalog_db
  warmup_years.each do |year|
    cached_listing("speakers:#{year}") { JSON.generate(data: year_speakers(year)) }
    cached_listing("sponsors:#{year}") do
      rows = catalog_db[:v1_year_sponsors].where(year: year).order(:name).all
      JSON.generate(data: rows.map { |r| stringify_keys(r) })
    end
  end
rescue StandardError => e
  warn "catalog warmup failed: #{e.message}"
end

# After CRaC restore (or a normal Puma boot): copy restore-time env, warm the
# catalog, then register with the CMS using restore-time secrets.
def acquire_after_restore!
  refresh_env_after_restore!
  warmup_catalog!
  register_with_elixir
end
