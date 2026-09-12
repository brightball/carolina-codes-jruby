# frozen_string_literal: true

# After CRaC --restore, confirm Ruby ENV / jdbc_database_url see restore-time
# DATABASE_URL (java.lang.System.getenv), not the checkpoint snapshot.
require_relative "../app"
acquire_after_restore!
url = ENV["DATABASE_URL"].to_s
jdbc = jdbc_database_url
host = begin
  URI.parse(url).host
rescue StandardError
  nil
end
ok = !host.to_s.empty? && jdbc.include?(host)
puts "RESTORE_ENV_HOST=#{host}"
puts "RESTORE_JDBC_OK=#{ok}"
exit(ok ? 0 : 1)
