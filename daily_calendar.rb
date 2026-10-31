# frozen_string_literal: true

require 'base64'
require 'date'
require 'json'
require 'net/http'
require 'optparse'
require 'time'
require 'uri'

module DailyCalendar
  class Error < StandardError; end

  def self.load_env(path = '.env')
    return unless File.exist?(path)

    File.foreach(path) do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      key, value = line.split('=', 2)
      raise Error, "Invalid environment setting: #{key}" unless value

      ENV[key.strip] ||= value.strip.sub(/\A["']/, '').sub(/["']\z/, '')
    end
  end

  def self.required(key)
    value = ENV.fetch(key, '').strip
    raise Error, "Missing environment variable: #{key}" if value.empty?

    value
  end

  def self.request_json(url, form: nil, headers: {})
    uri = URI(url)
    request = form ? Net::HTTP::Post.new(uri, headers) : Net::HTTP::Get.new(uri, headers)
    request.set_form_data(form) if form
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
      http.request(request)
    end
    unless response.is_a?(Net::HTTPSuccess)
      # Provider bodies can include personal information; do not log them.
      raise Error, "Provider request failed (HTTP #{response.code}); check credentials and provider dashboard."
    end
    JSON.parse(response.body)
  rescue JSON::ParserError
    raise Error, 'Provider returned an invalid response.'
  rescue IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, SocketError
    raise Error, 'Provider connection failed; check network and provider status.'
  end

  def self.configure_timezone(name)
    # Ruby uses the host tzdata through ENV['TZ']; validate to avoid silent UTC fallback.
    roots = ['/usr/share/zoneinfo', '/usr/share/lib/zoneinfo']
    valid = name.match?(/\A[A-Za-z0-9_+\/-]+\z/) && !name.split('/').include?('..') &&
            roots.any? { |root| File.file?(File.join(root, name)) }
    raise Error, "Unknown IANA time zone: #{name}" unless valid

    ENV['TZ'] = name
  end

  def self.fetch_events(day)
    token = request_json('https://oauth2.googleapis.com/token', form: {
      'client_id' => required('GOOGLE_CLIENT_ID'),
      'client_secret' => required('GOOGLE_CLIENT_SECRET'),
      'refresh_token' => required('GOOGLE_REFRESH_TOKEN'),
      'grant_type' => 'refresh_token'
    }).fetch('access_token')
    tomorrow = day + 1
    start_at = Time.local(day.year, day.month, day.day)
    end_at = Time.local(tomorrow.year, tomorrow.month, tomorrow.day)
    calendars = ENV.fetch('GOOGLE_CALENDAR_IDS', 'primary').split(',').map(&:strip).reject(&:empty?).uniq
    raise Error, 'GOOGLE_CALENDAR_IDS must contain at least one calendar' if calendars.empty?

    calendars.flat_map do |calendar|
      params = { 'timeMin' => start_at.iso8601, 'timeMax' => end_at.iso8601,
                 'singleEvents' => 'true', 'orderBy' => 'startTime', 'maxResults' => '2500',
                 'timeZone' => ENV.fetch('TZ') }
      events = []
      loop do
        calendar_path = URI.encode_www_form_component(calendar).gsub('+', '%20')
        page = request_json("https://www.googleapis.com/calendar/v3/calendars/#{calendar_path}/events?#{URI.encode_www_form(params)}",
                            headers: { 'Authorization' => "Bearer #{token}" })
        events.concat(page.fetch('items', []).reject do |event|
          event['status'] == 'cancelled' || event.fetch('attendees', []).any? do |attendee|
            attendee['self'] && attendee['responseStatus'] == 'declined'
          end
        end)
        break unless page['nextPageToken']

        params['pageToken'] = page['nextPageToken']
      end
      events
    end
  end

  def self.event_start(event)
    start = event.fetch('start')
    return Time.iso8601(start.fetch('dateTime')).getlocal unless start['date']

    date = Date.iso8601(start['date'])
    Time.local(date.year, date.month, date.day)
  end

  def self.clean(value)
    value.to_s.split.join(' ')
  end

  def self.format_summary(events, day, timezone, limit: 1200)
    raise Error, 'MAX_SMS_CHARACTERS must be between 160 and 1500' unless (160..1500).cover?(limit)

    header = "#{day.strftime('%a, %b')} #{day.day} (#{timezone})"
    return "#{header}\nNo events today. Enjoy your day!" if events.empty?

    lines = events.sort_by { |event| [event.fetch('start').key?('date') ? 0 : 1, event_start(event)] }.map do |event|
      start_at = event_start(event)
      label = if event.fetch('start').key?('date')
                'All day'
              elsif start_at.to_date < day
                'Ongoing'
              else
                start_at.strftime('%l:%M%P').strip
              end
      title = clean(event['summary'])
      title = '(Untitled)' if title.empty?
      location = clean(event['location'])
      "#{label}: #{title}" + (location.empty? ? '' : " @ #{location}")
    end
    result = "#{header}\n#{events.length} event#{events.length == 1 ? '' : 's'}"
    lines.each_with_index do |line, index|
      remaining = lines.length - index - 1
      suffix = remaining.positive? ? "\n+#{remaining} more; see Calendar." : ''
      available = limit - result.length - 1 - suffix.length
      if line.length > available
        result += if available >= 12
                    "\n#{line[0, available - 3]}...#{suffix}"
                  else
                    "\n+#{lines.length - index} more; see Calendar."
                  end
        break
      end
      result += "\n#{line}"
    end
    result[0, limit]
  end

  def self.send_sms(body)
    sid = required('TWILIO_ACCOUNT_SID')
    sender = required('TWILIO_FROM_NUMBER')
    recipient = required('SMS_TO_NUMBER')
    unless [sender, recipient].all? { |number| number.match?(/\A\+[1-9]\d{7,14}\z/) }
      raise Error, 'Phone numbers must use E.164 format, such as +15551234567'
    end
    auth = Base64.strict_encode64("#{sid}:#{required('TWILIO_AUTH_TOKEN')}")
    response = request_json("https://api.twilio.com/2010-04-01/Accounts/#{sid}/Messages.json",
                            form: { 'To' => recipient, 'From' => sender, 'Body' => body },
                            headers: { 'Authorization' => "Basic #{auth}" })
    puts "SMS accepted by Twilio: #{response.fetch('sid')} (delivery status: #{response.fetch('status')})"
  end

  def self.main(argv = ARGV)
    options = {}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby daily_calendar.rb [--preview | --send-now]'
      parser.on('--preview', 'Print today\'s summary without sending, regardless of hour') { options[:preview] = true }
      parser.on('--send-now', 'Send now regardless of configured hour') { options[:send_now] = true }
      parser.on('-h', '--help') { puts parser; return }
    end.parse!(argv)
    raise Error, 'Choose either --preview or --send-now' if options[:preview] && options[:send_now]
    raise Error, 'Unexpected command arguments' unless argv.empty?

    load_env
    timezone = ENV.fetch('TIMEZONE', 'America/New_York')
    configure_timezone(timezone)
    hour = Integer(ENV.fetch('SEND_HOUR', '7'), 10)
    raise Error, 'SEND_HOUR must be between 0 and 23' unless (0..23).cover?(hour)

    now = Time.now
    # During fall-back, only the first occurrence of a repeated hour sends.
    repeated_hour = (now - 3600).strftime('%Y-%m-%d %H') == now.strftime('%Y-%m-%d %H')
    unless options[:preview] || options[:send_now] || (now.hour == hour && !repeated_hour)
      puts 'Outside the configured delivery hour; skipped.'
      return
    end
    summary = format_summary(fetch_events(now.to_date), now.to_date, timezone,
                             limit: Integer(ENV.fetch('MAX_SMS_CHARACTERS', '1200'), 10))
    options[:preview] ? puts(summary) : send_sms(summary)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    DailyCalendar.main
  rescue DailyCalendar::Error, ArgumentError, KeyError, OptionParser::ParseError => e
    warn "Error: #{e.message}"
    exit 1
  end
end
