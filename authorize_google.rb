# frozen_string_literal: true

# Run locally with a Google OAuth Desktop app credentials JSON file.
require_relative 'daily_calendar'
require 'securerandom'
require 'socket'
require 'timeout'

begin
  credentials_path = ARGV.fetch(0, 'client_secret.json')
  output_path = 'google-token.json'
  raise DailyCalendar::Error, "#{output_path} already exists; move it aside before authorizing again." if File.exist?(output_path)

  credentials = JSON.parse(File.read(credentials_path)).fetch('installed')
  client_id = credentials.fetch('client_id')
  client_secret = credentials.fetch('client_secret')
  server = TCPServer.new('127.0.0.1', 0)
  redirect_uri = "http://127.0.0.1:#{server.addr[1]}/callback"
  state = SecureRandom.hex(32)
  verifier = SecureRandom.urlsafe_base64(48)
  challenge = Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(verifier), padding: false)
  params = {
    'client_id' => client_id, 'redirect_uri' => redirect_uri, 'response_type' => 'code',
    'scope' => 'https://www.googleapis.com/auth/calendar.events.readonly',
    'access_type' => 'offline', 'prompt' => 'consent', 'state' => state,
    'code_challenge' => challenge, 'code_challenge_method' => 'S256'
  }
  puts "Open this URL in your browser on this computer and approve read-only calendar access:\n\n"
  puts "https://accounts.google.com/o/oauth2/v2/auth?#{URI.encode_www_form(params)}"
  puts "\nWaiting up to 5 minutes for Google to redirect to localhost..."
  code = Timeout.timeout(300) do
    loop do
      socket = server.accept
      begin
        request_line = Timeout.timeout(10) { socket.gets }
        target = request_line.to_s.split(' ')[1]
        uri = URI(target.to_s)
        query = URI.decode_www_form(uri.query.to_s).to_h
        valid = uri.path == '/callback' && query['state'] == state
        message = valid ? 'Authorization received. You may close this tab.' : 'Invalid callback.'
        socket.write("HTTP/1.1 #{valid ? '200 OK' : '400 Bad Request'}\r\nContent-Type: text/plain\r\nContent-Length: #{message.bytesize}\r\nConnection: close\r\n\r\n#{message}")
        next unless valid

        raise DailyCalendar::Error, 'Google authorization was declined.' if query['error']
        break query.fetch('code')
      ensure
        socket.close
      end
    end
  end
  token = DailyCalendar.request_json('https://oauth2.googleapis.com/token', form: {
    'client_id' => client_id, 'client_secret' => client_secret,
    'code' => code, 'code_verifier' => verifier,
    'redirect_uri' => redirect_uri, 'grant_type' => 'authorization_code'
  })
  output = { 'GOOGLE_CLIENT_ID' => client_id, 'GOOGLE_CLIENT_SECRET' => client_secret,
             'GOOGLE_REFRESH_TOKEN' => token.fetch('refresh_token') }
  File.open(output_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.pretty_generate(output) + "\n")
  end
  puts "Saved credentials to #{output_path} (owner-readable only). Copy its three values to .env and Render's environment settings."
rescue DailyCalendar::Error, JSON::ParserError, KeyError, SystemCallError, Timeout::Error, URI::InvalidURIError => e
  warn "Authorization failed: #{e.message}"
  warn 'Use an OAuth Desktop app JSON file and run this helper on your own computer.'
  exit 1
ensure
  server&.close
end
