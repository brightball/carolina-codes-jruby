# frozen_string_literal: true

require "sinatra"
require "json"
require "sequel"
require "net/http"
require "uri"

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
  jdbc += "?user=#{user}" if user
  jdbc += "&password=#{pass}" if pass && user
  jdbc
end

DB = Sequel.connect(jdbc_database_url)

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

set :bind, "0.0.0.0"
set :port, Integer(ENV.fetch("PORT", "4003"))
disable :protection

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
  rows = DB[:v1_years].order(Sequel.desc(:year)).all
  JSON.generate(data: rows.map { |r| stringify_keys(r) })
end

get "/v1/speakers" do
  if params["year"]
    year = Integer(params["year"])
    JSON.generate(data: year_speakers(year))
  else
    dataset = DB[:v1_speakers].order(:last_name, :first_name)
    JSON.generate(data: dataset.all.map { |r| stringify_keys(r) })
  end
end

get %r{/v1/speakers/(\d{4})/([^/]+)} do |year, slug|
  year = Integer(year)
  speaker = DB[:v1_speakers].where(slug: slug).first
  halt 404, JSON.generate(error: "not_found") unless speaker

  talks = DB[:v1_talks].where(speaker_slug: slug, year: year).all
  halt 404, JSON.generate(error: "not_found") if talks.empty?

  years = DB[:v1_talks].where(speaker_slug: slug).select_map(:year).uniq.sort.reverse
  payload = stringify_keys(speaker).merge(
    "year" => year,
    "years" => years,
    "other_years" => years.reject { |y| y == year },
    "talks" => talks.map { |t| stringify_keys(t) }
  )
  JSON.generate(data: payload)
end

get "/v1/speakers/:slug" do
  speaker = DB[:v1_speakers].where(slug: params["slug"]).first
  halt 404, JSON.generate(error: "not_found") unless speaker

  talks = DB[:v1_talks].where(speaker_slug: params["slug"]).all
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
    rows = DB[:v1_year_sponsors].where(year: year).order(:name).all
    JSON.generate(data: rows.map { |r| stringify_keys(r) })
  else
    dataset = DB[:v1_sponsors].order(:name)
    JSON.generate(data: dataset.all.map { |r| stringify_keys(r) })
  end
end

get %r{/v1/sponsors/(\d{4})/([^/]+)} do |year, slug|
  year = Integer(year)
  row = DB[:v1_year_sponsors].where(year: year, slug: slug).first
  halt 404, JSON.generate(error: "not_found") unless row

  years = DB[:v1_sponsorships].where(sponsor_slug: slug).select_map(:year).uniq.sort.reverse
  payload = stringify_keys(row).merge(
    "years" => years,
    "other_years" => years.reject { |y| y == year },
    "sponsorships" => DB[:v1_sponsorships].where(sponsor_slug: slug).all.map { |s| stringify_keys(s) }
  )
  JSON.generate(data: payload)
end

get "/v1/sponsors/:slug" do
  sponsor = DB[:v1_sponsors].where(slug: params["slug"]).first
  halt 404, JSON.generate(error: "not_found") unless sponsor

  sponsorships = DB[:v1_sponsorships].where(sponsor_slug: params["slug"]).all
  payload = stringify_keys(sponsor).merge("sponsorships" => sponsorships.map { |s| stringify_keys(s) })
  JSON.generate(data: payload)
end

def year_speakers(year)
  slugs = DB[:v1_talks].where(year: year).select_map(:speaker_slug).uniq
  speakers = DB[:v1_speakers].where(slug: slugs).order(:last_name, :first_name).all
  speakers.map do |speaker|
    talks = DB[:v1_talks].where(speaker_slug: speaker[:slug], year: year).all
    stringify_keys(speaker).merge(
      "year" => year,
      "talks" => talks.map { |t| stringify_keys(t) }
    )
  end
end

def stringify_keys(row)
  row.each_with_object({}) do |(key, value), acc|
    acc[key.to_s] = value
  end
end

def register_with_elixir
  url = ENV["CAROLINA_URL"]
  token = ENV["POLYGLOT_REGISTER_TOKEN"]
  return if url.nil? || url.empty? || token.nil? || token.empty?

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

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{token}"
  req["Content-Type"] = "application/json"
  req.body = JSON.generate(body)
  http.request(req)
rescue StandardError => e
  warn "registration failed: #{e.message}"
end

register_with_elixir
