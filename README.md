# Daily Calendar SMS

A small Ruby app that sends your Google Calendar agenda to your phone using Twilio. Deploy it as a Render cron job; no web server or database is required. Uses the Ruby standard library, with no runtime gems.

Features: multiple calendars, recurring events, all-day and overnight events, local event times, pagination, declined-event filtering, and bounded message length. Empty days get a “No events today” message. Preview mode never sends an SMS.

## 1. Connect Google Calendar

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project and enable **Google Calendar API**.
2. Configure **Google Auth Platform → Branding / Audience / Data Access**. For a personal Gmail account, select External and add yourself as a test user. Add the scope `https://www.googleapis.com/auth/calendar.events.readonly`.
3. Create an OAuth client with application type **Desktop app**. Download its JSON file to this directory as `client_secret.json`. The helper uses a loopback redirect on your computer; no Render callback URL is needed.
4. With Ruby 3.1+ installed, run locally:

   ```sh
   ruby authorize_google.rb client_secret.json
   ```

5. Open the printed URL on the same computer, sign into Google, and approve calendar access. The helper saves `google-token.json` with restricted file permissions. Copy its three credential values into `.env` and later into Render. These files are gitignored; keep them private.

**Important:** Google's External apps in Testing generally receive refresh tokens that expire after seven days for calendar access. To keep daily delivery running, switch the consent screen's publishing status to **In production**, then authorize again. A personal app can show an unverified-app warning; use it only for your own project. Workspace administrators may restrict access. See [Google's token-expiration documentation](https://developers.google.com/identity/protocols/oauth2#expiration).

## 2. Configure SMS and test locally

Create a [Twilio account](https://www.twilio.com/), obtain an SMS-capable phone number, and copy its Account SID and Auth Token. Trial accounts require a verified recipient; sending may also require registration for your sender type and destination country. Follow Twilio's account setup prompts.

```sh
cp .env.example .env
```

Fill in `.env`:

| Variable | Value |
| --- | --- |
| `GOOGLE_CLIENT_ID` | From `google-token.json` |
| `GOOGLE_CLIENT_SECRET` | From `google-token.json` |
| `GOOGLE_REFRESH_TOKEN` | From `google-token.json` |
| `GOOGLE_CALENDAR_IDS` | `primary`, or comma-separated calendar IDs from Google Calendar settings |
| `TWILIO_ACCOUNT_SID` | Your Twilio Account SID |
| `TWILIO_AUTH_TOKEN` | Your Twilio Auth Token |
| `TWILIO_FROM_NUMBER` | Your SMS-capable Twilio number, such as `+15551234567` |
| `SMS_TO_NUMBER` | Your phone number in international E.164 format |
| `TIMEZONE` | IANA name, default `America/New_York` |
| `SEND_HOUR` | Local hour, 0–23, default `7` |
| `MAX_SMS_CHARACTERS` | Optional, 160–1500, default `1200` |

No environment export command is needed: the app loads `.env`, and Render environment variables take precedence.

```sh
ruby daily_calendar.rb --preview
ruby daily_calendar.rb --send-now
```

The second command sends a real SMS. A summary looks like:

```text
Sat, Oct 31 (America/New_York)
3 events
All day: Halloween
9:00am: Breakfast @ Main Street Cafe
1:00pm: Team meeting
```

SMS messages can use multiple billable segments, especially with emoji or other Unicode characters. The character limit bounds the digest, rather than guaranteeing one segment. Long agendas are shortened with a notice to check Calendar. Twilio accepting the message does not guarantee carrier delivery; check its Messaging logs for delivery failures. See [Twilio's Message API](https://www.twilio.com/docs/messaging/api/message-resource).

## 3. Deploy to Render

1. Push this repository to GitHub or GitLab.
2. In [Render](https://dashboard.render.com/), choose **New → Blueprint**, connect the repository, and select `render.yaml`.
3. Enter the seven secret values requested by the Blueprint: the three Google credentials, Twilio SID and token, and the two phone numbers. Check `TIMEZONE`, `SEND_HOUR`, and `GOOGLE_CALENDAR_IDS` in the service's environment settings.
4. Deploy. For an immediate end-to-end check, temporarily change the cron job command to `ruby daily_calendar.rb --send-now`, trigger a run, then restore `ruby daily_calendar.rb`. This sends a real SMS.

Render runs `0 * * * *` in UTC. The app checks your local hour and skips other runs, so the default 7 a.m. delivery adjusts to daylight saving time automatically. Choose a morning hour such as 7: a nonexistent hour during spring-forward is skipped. During fall-back, the repeated occurrence of an hour is skipped. Delivery is near the hour, depending on scheduling and API latency. See [Render cron jobs](https://render.com/docs/cronjobs) and [Blueprint configuration](https://render.com/docs/blueprint-spec).

Render cron compute and Twilio messaging are paid services; check their current pricing before deployment. Hourly runs outside the configured hour make no provider calls. This app sends to one configured recipient; it is a personal utility.

## Operations and limitations

- There is no persistent delivery ledger. Manually rerunning the job during the delivery hour, or using `--send-now`, can send another copy. The job does not retry SMS requests automatically because an ambiguous network failure could otherwise produce duplicates.
- A missed or failed scheduled run is not caught up later. Render marks failures in job logs. Check those logs and Twilio's delivery logs if a summary is missing.
- Google access uses a refresh token and read-only event scope. Revoking access or an expired token requires running the authorization helper again and replacing the token in Render.
- Each selected calendar is summarized independently; an invitation appearing on multiple selected calendars may appear twice.
- Normal logs omit calendar contents and credentials. `--preview` intentionally prints your agenda, so use it in a private terminal.
- Never commit `.env`, downloaded Google client secrets, or `google-token.json`.

Run the mocked unit tests (no credentials, external requests, or texts):

```sh
ruby tests/daily_calendar_test.rb
```
