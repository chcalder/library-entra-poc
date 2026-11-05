# frozen_string_literal: true

# ENTRA MIGRATION (phase 2, API-3): new file.
# The NEW capability: write due-date reminders into the patron's own Outlook
# calendar through Microsoft Graph, as the patron. Only possible once the
# Patron API holds a delegated Graph token, i.e. after the OBO exchange.
# Under CAS + API key there is no user token to exchange, so this can't exist.
class GraphCalendar
  include GraphHttp

  def initialize(base_url: GraphHttp::BASE_URL, time_zone: "UTC", transport: nil)
    @base_url = base_url.chomp("/")
    @time_zone = time_zone
    @transport = transport || method(:perform)
  end

  def create_due_date_reminder(access_token, loan)
    due = loan[:due_date]
    event = {
      subject: "Library due date: #{loan[:title]}",
      body: { contentType: "text", content: "\"#{loan[:title]}\" is due back to the library on #{due}." },
      start: { dateTime: "#{due}T09:00:00", timeZone: @time_zone },
      end: { dateTime: "#{due}T09:30:00", timeZone: @time_zone },
      isReminderOn: true,
      reminderMinutesBeforeStart: 24 * 60,
      showAs: "free",
      categories: ["Library"],
      # Graph de-duplicates on transactionId, so clicking twice won't double-book.
      transactionId: "library-loan-#{loan[:id]}-#{due}"
    }

    status, headers, body = @transport.call(:post, "#{@base_url}/me/events", access_token, event)
    return JSON.parse(body) if status == 201

    raise_graph_error(status, headers, body)
  end
end
