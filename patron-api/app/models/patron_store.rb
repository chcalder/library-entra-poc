# frozen_string_literal: true

require "date"
require "monitor"
require "yaml"

# In-memory stand-in for the ILS patron database. Plain Ruby (no Rails) so it
# can be tested without the framework.
class PatronStore
  class NotFound < StandardError; end

  # How CAS eduPersonAffiliation values map to the Entra app roles defined on
  # the Patron API registration. The same table drives role assignment when
  # test users are created (infra/entra/setup-app-registrations.sh).
  AFFILIATION_TO_ROLE = {
    "student" => "Student",
    "faculty" => "Faculty",
    "staff" => "Staff",
    "librarian" => "Librarian",
    "alum" => "Alumni"
  }.freeze

  def self.instance
    @instance ||= load(File.expand_path("../../data/patrons.yml", __dir__),
                       auto_provision: ENV["DEMO_AUTO_PROVISION"] == "true")
  end

  def self.load(path, today: Date.today, auto_provision: false)
    new(YAML.load_file(path), today: today, auto_provision: auto_provision)
  end

  # auto_provision (demo only): an unknown NetID gets a copy of the jstudent
  # record, so you can sign in with your own licensed Entra account (Graph
  # calendar writes need a real Exchange Online mailbox).
  def initialize(data, today: Date.today, auto_provision: false)
    @auto_provision = auto_provision
    @mutex = Monitor.new # re-entrant: link_oid -> find! -> provision
    @patrons = data.to_h do |netid, record|
      loans = Array(record["loans"]).map do |loan|
        { id: loan["id"], title: loan["title"], due_date: today + loan["due_in_days"].to_i }
      end
      fines = Array(record["fines"]).map do |fine|
        { id: fine["id"], amount: fine["amount"].to_f, reason: fine["reason"], status: fine["status"] }
      end
      [netid, { netid: netid, name: record["name"], email: record["email"], barcode: record["barcode"],
                affiliations: Array(record["affiliations"]), entra_oid: record["entra_oid"],
                loans: loans, fines: fines }]
    end
    @today = today
  end

  def find!(netid)
    key = netid.to_s.downcase
    @patrons.fetch(key) do
      raise NotFound, "No patron record for #{netid}" unless @auto_provision && !key.empty?

      provision(key)
    end
  end

  def roles_for(netid)
    find!(netid)[:affiliations].filter_map { |a| AFFILIATION_TO_ROLE[a] }
  end

  # ENTRA MIGRATION (phase 1, AUTH-3): new, with find_by_oid and the entra_oid field.
  # Identifier crosswalk: the first time a patron arrives with an Entra token,
  # record their immutable object ID next to the NetID. After cutover, look
  # patrons up by oid so a renamed UPN can't attach to someone else's record.
  def link_oid(netid, oid)
    @mutex.synchronize do
      patron = find!(netid)
      if patron[:entra_oid] && patron[:entra_oid] != oid
        raise NotFound, "NetID #{netid} is already linked to a different Entra account"
      end

      patron[:entra_oid] ||= oid
    end
  end

  def find_by_oid(oid)
    @patrons.values.find { |p| p[:entra_oid] == oid }
  end

  def profile(netid)
    find!(netid).slice(:netid, :name, :email, :barcode, :affiliations, :entra_oid)
  end

  def loans(netid)
    find!(netid)[:loans].map { |l| serialize_loan(l) }
  end

  def fines(netid)
    find!(netid)[:fines].map(&:dup)
  end

  def waive_fine!(netid, fine_id)
    @mutex.synchronize do
      fine = find!(netid)[:fines].find { |f| f[:id] == fine_id } or raise NotFound, "No fine #{fine_id}"
      fine[:status] = "waived"
      fine.dup
    end
  end

  def overdue_loans
    @patrons.values.flat_map do |patron|
      patron[:loans].select { |l| l[:due_date] < @today }.map do |loan|
        serialize_loan(loan).merge(netid: patron[:netid], email: patron[:email], name: patron[:name])
      end
    end
  end

  private

  def provision(netid)
    @mutex.synchronize do
      @patrons[netid] ||= Marshal.load(Marshal.dump(@patrons.fetch("jstudent"))).merge(
        netid: netid, name: netid, email: nil, barcode: "2123400#{netid.sum.to_s.rjust(7, '0')}", entra_oid: nil
      )
    end
  end

  def serialize_loan(loan)
    loan.merge(due_date: loan[:due_date].iso8601, overdue: loan[:due_date] < @today)
  end
end
