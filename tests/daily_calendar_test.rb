# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../daily_calendar'

class DailyCalendarTest < Minitest::Test
  def setup
    @old_env = ENV.to_h
    DailyCalendar.configure_timezone('America/New_York')
    @day = Date.new(2026, 10, 31)
  end

  def teardown
    ENV.replace(@old_env)
  end

  def event(title, start)
    { 'summary' => title, 'start' => start }
  end

  def test_empty_day
    assert_includes DailyCalendar.format_summary([], @day, 'America/New_York'), 'No events today.'
  end

  def test_timezone_sorting_all_day_and_ongoing_events
    events = [event("Team\nmeeting", { 'dateTime' => '2026-10-31T17:00:00Z' }),
              event('Overnight', { 'dateTime' => '2026-10-30T23:00:00-04:00' }),
              event('Holiday', { 'date' => '2026-10-31' }),
              event('Breakfast', { 'dateTime' => '2026-10-31T08:00:00-04:00' })]
    body = DailyCalendar.format_summary(events, @day, 'America/New_York')
    assert_includes body, '1:00pm: Team meeting'
    assert_operator body.index('All day: Holiday'), :<, body.index('Ongoing: Overnight')
    assert_operator body.index('8:00am: Breakfast'), :<, body.index('1:00pm: Team')
  end

  def test_truncation_preserves_notice
    events = 10.times.map { event('A' * 200, { 'date' => '2026-10-31' }) }
    body = DailyCalendar.format_summary(events, @day, 'America/New_York', limit: 160)
    assert_operator body.length, :<=, 160
    assert_includes body, '+9 more; see Calendar.'
  end

  def test_fetch_paginates_filters_declined_and_uses_local_day_boundaries
    calls = []
    responses = [{ 'access_token' => 'test-token' },
                 { 'items' => [event('First', { 'date' => '2026-10-31' }),
                                 { 'status' => 'cancelled' },
                                 { 'attendees' => [{ 'self' => true, 'responseStatus' => 'declined' }] }],
                   'nextPageToken' => 'next' },
                 { 'items' => [event('Second', { 'date' => '2026-10-31' })] }]
    %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_REFRESH_TOKEN].each { |key| ENV[key] = 'test' }
    ENV['GOOGLE_CALENDAR_IDS'] = 'primary'
    fake = lambda do |url, **options|
      calls << [url, options]
      responses.shift
    end
    DailyCalendar.stub(:request_json, fake) do
      assert_equal %w[First Second], DailyCalendar.fetch_events(@day).map { |e| e['summary'] }
    end
    params = URI.decode_www_form(URI(calls[1][0]).query).to_h
    assert_equal '2026-10-31T00:00:00-04:00', params['timeMin']
    assert_equal '2026-11-01T00:00:00-04:00', params['timeMax']
    assert_includes calls[2][0], 'pageToken=next'
  end

  def test_dst_day_is_25_hours
    start_at = Time.local(2026, 11, 1)
    end_at = Time.local(2026, 11, 2)
    assert_equal 25 * 3600, end_at - start_at
  end

  def test_wrong_hour_does_not_call_providers
    ENV['SEND_HOUR'] = '7'
    now = Time.local(2026, 10, 31, 12)
    Time.stub(:now, now) do
      DailyCalendar.stub(:fetch_events, ->(*) { flunk 'Should not call Google' }) do
        assert_output(/skipped/) { DailyCalendar.main([]) }
      end
    end
  end

  def test_sms_request
    ENV['TWILIO_ACCOUNT_SID'] = 'ACtest'
    ENV['TWILIO_AUTH_TOKEN'] = 'secret'
    ENV['TWILIO_FROM_NUMBER'] = '+15551234567'
    ENV['SMS_TO_NUMBER'] = '+15557654321'
    fake = lambda do |url, form:, headers:|
      assert_equal 'https://api.twilio.com/2010-04-01/Accounts/ACtest/Messages.json', url
      assert_equal 'Hello', form['Body']
      assert_equal '+15557654321', form['To']
      assert_equal "Basic #{Base64.strict_encode64('ACtest:secret')}", headers['Authorization']
      { 'sid' => 'SMtest', 'status' => 'queued' }
    end
    DailyCalendar.stub(:request_json, fake) do
      assert_output(/SMS accepted/) { DailyCalendar.send_sms('Hello') }
    end
  end

  def test_repeated_fall_back_hour_does_not_send_twice
    ENV['SEND_HOUR'] = '1'
    now = Time.iso8601('2026-11-01T01:00:00-05:00').getlocal
    Time.stub(:now, now) do
      DailyCalendar.stub(:fetch_events, ->(*) { flunk 'Repeated hour should skip' }) do
        assert_output(/skipped/) { DailyCalendar.main([]) }
      end
    end
  end

  def test_preview_bypasses_hour_and_never_sends
    ENV['SEND_HOUR'] = '7'
    now = Time.local(2026, 10, 31, 12)
    Time.stub(:now, now) do
      DailyCalendar.stub(:fetch_events, []) do
        DailyCalendar.stub(:send_sms, ->(*) { flunk 'Preview must not send SMS' }) do
          assert_output(/No events today/) { DailyCalendar.main(['--preview']) }
        end
      end
    end
  end

  def test_send_at_configured_hour
    ENV['SEND_HOUR'] = '7'
    now = Time.local(2026, 10, 31, 7)
    delivered = []
    Time.stub(:now, now) do
      DailyCalendar.stub(:fetch_events, []) do
        DailyCalendar.stub(:send_sms, ->(body) { delivered << body }) do
          DailyCalendar.main([])
        end
      end
    end
    assert_equal 1, delivered.length
    assert_includes delivered.first, 'No events today'
  end

  def test_unknown_timezone_rejected
    assert_raises(DailyCalendar::Error) { DailyCalendar.configure_timezone('Not/AZone') }
  end
end
