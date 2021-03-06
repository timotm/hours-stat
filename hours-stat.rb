#!/usr/bin/env ruby
# coding: utf-8

require 'date'
require 'json'
require 'optparse'

Encoding.default_external = Encoding::UTF_8

$options = {}
OptionParser.new do |opt|
  opt.on('--lang LANG', %i[fi en], 'Language (fi/en)') { |l| $options[:lang] = l }
  opt.on('--hours HOURS', Float, 'Number of working hours per day. If not given, guessed per year') do |h|
    $options[:hours_per_day] = h
  end
end.parse!

$lang = $options[:lang] || :fi

$months = { fi: %w[Tammi Helmi Maalis Huhti Touko Kesä Heinä Elo Syys Loka Marras Joulu].map { |m| "#{m}kuu" },
            en: %w[January February March April May June July August September October November December] }

$strings = { unknown_project: {
  fi: '*** Tuntematon projekti %{project}, oletetaan laskuttamaton',
  en: "*** Unknown project %{project}, assuming it's non-billable"
},
             year: {
               fi: '#### Vuosi %{year} #####',
               en: '#### Year %{year} #####'
             },
             month_info: {
               fi: "\n  ### %{month} %{year} (%{business_days} arkipäivää, %{holidays} arkipäiviin osuvaa vapaapäivää "\
                   'ja %{workdays} työpäivää)',
               en: "\n  ### %{month} %{year} (%{business_days} business days, %{holidays} holidays and %{workdays} "\
                   'work days)'
             },
             month_total: {
               fi: '  Yhteensä %{done_hours} h kuukauden %{hours_in_month} työtunnista joista',
               en: '  Total of %{done_hours} h out of %{hours_in_month} of the month, out of which'
             },
             billable: {
               fi: '    - laskutettavia %{hours} h, laskutusaste %{ratio} %%',
               en: '    - billable %{hours} h, billing ratio %{ratio} %%'
             },
             hours_per_code: {
               fi: "       %{hours}\t%{code}",
               en: "       %{hours}\t%{code}"
             },
             non_billable: {
               fi: '    - laskutettamattomia %{hours} h, laskuttamattomuusaste %{ratio} %%',
               en: '    - non-billable %{hours} h, non-billing ratio %{ratio} %%'
             },
             year_total: {
               fi: "\nVuonna %{year} yhteensä (olettaen %{hours_per_day} h työpäivän):\n%{done_hours} h vuoden "\
                   '%{hours_in_year} työtunnista joista laskutettavia %{billable_in_year} h, laskutusaste '\
                   "%{billing_ratio} %\n",
               en: "\nYear %{year} total (assuming %{hours_per_day} h working day):\n%{done_hours} h out of "\
                   '%{hours_in_year} hours of the year, out of which %{billable_in_year} h billable, billing ratio '\
                   "%{billing_ratio} %\n\n"
             } }

$hours_dir = "#{ENV['HOME']}/.hours"

def t(key)
  $strings[key][$lang]
end

class HolidayCount
  def key_for_date(d)
    "#{d.year}-#{d.month}"
  end

  def initialize
    @holidays_per_month = Hash.new(0)
    @country_per_year = Hash.new(:fin)

    File.open("#{$hours_dir}/holidays.txt") do |f|
      while (line = f.gets)
        d = Date.strptime(line.split(' ')[0], '%d.%m.%Y')
        # Don't count holidays that are either in the weekends or in the future
        @holidays_per_month[key_for_date(d)] += 1 if !d.saturday? && !d.sunday? && (d <= Date.today)
        if /#{d.year}.*(uuden|loppiai|pääsiäis|helatorstai|vappu|helatorstai|juhannus|itsenäisyys|joulu)/i =~ line
          @country_per_year[d.year] = :fin
        elsif /
           #{d.year}
           .*
           (new year|martin luther king|washington|memorial|independence|thanksgiving|christmas)
           /xi =~ line
          @country_per_year[d.year] = :us
        end
      end
    end
  end

  def for_month(year, month)
    @holidays_per_month[key_for_date(Date.new(year, month, 1))]
  end

  def country_for_year(year)
    @country_per_year[year]
  end
end

class String
  def colorize(text, color_code)
    "#{color_code}#{text}\033[0m"
  end

  def red
    colorize(self, "\033[31m")
  end
end

class ProjectStore
  attr_reader :projects

  def initialize
    @projects = File.open("#{$hours_dir}/projects.json") do |f|
      j = JSON.parse(f.read)
      h = {}
      j['projects'].each { |e| h[e['name']] = e['billable'] }
      h
    end
  end

  def billable(tuntikoodi)
    project = tuntikoodi.split('-')[0]

    warn format(t(:unknown_project).red, project: project) unless @projects.key? project
    @projects[project] || false
  end
end

project_store = ProjectStore.new

# http://stackoverflow.com/questions/4027768/calculate-number-of-business-days-between-two-days
#
# Calculates the number of business days in range (start_date, end_date]
#
# @param start_date [Date]
# @param end_date [Date]
#
# @return [Fixnum]
def business_days_between(start_date, end_date)
  days_between = (end_date - start_date).to_i
  return 0 unless days_between > 0

  whole_weeks, extra_days = days_between.divmod(7)

  unless extra_days.zero?
    extra_days -= if start_date.next_day.wday <= end_date.wday
                    [start_date.next_day.sunday?, end_date.saturday?].count(true)
                  else
                    2
                  end
  end

  (whole_weeks * 5) + extra_days
end

class Hash
  def nonzero_values_descending
    sort_by { |_, v| v }.select { |_, v| v > 0.0 }.reverse
  end
end

def perce(f)
  (f * 100).round(1).to_s
end

def div(dividend, divisor)
  divisor.zero? ? 0 : dividend / divisor
end

class HourStorage
  attr_reader :hours_by_year_month_code

  def initialize
    @hours_by_year_month_code = {}
  end

  def store_hours_for_date_code(d, code, hours)
    @hours_by_year_month_code[d.year] = {} unless @hours_by_year_month_code.key? d.year

    @hours_by_year_month_code[d.year][d.month] = Hash.new(0) unless @hours_by_year_month_code[d.year].key? d.month

    @hours_by_year_month_code[d.year][d.month][code] += hours
  end
end

hour_storage = HourStorage.new
$holiday_counter = HolidayCount.new

Dir.entries($hours_dir).select { |e| e.match(/[0-9]{4}_[0-9]{2}/) }.sort.each do |month|
  month_as_date = Date.strptime(month, '%Y_%m')

  month_dir = "#{$hours_dir}/#{month}"
  log_name = Dir.entries(month_dir).select { |e| e.match(/^[a-z0-9]+\.txt/) }.first
  File.open("#{month_dir}/#{log_name}") do |f|
    while (line = f.gets)
      next if line =~ /^ *#/

      (pvm, id, start, _end, tunnit, tuntikoodi,) = line.split "\t"
      pattern = '%Y-%m-%d'
      if pvm =~ /[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{4}/
        pattern = '%d.%m.%Y'
        tunnit = id
        tuntikoodi = start
      end
      if !tunnit.nil? && (Date.strptime(pvm, pattern) <= Date.today)
        hour_storage.store_hours_for_date_code(month_as_date, tuntikoodi, tunnit.tr(',', '.').to_f)
      end
    end
  end
end

def working_hours_per_day_for_year(year)
  $options[:hours_per_day] || { fin: 7.5, us: 8 }[$holiday_counter.country_for_year(year)]
end

hour_storage.hours_by_year_month_code.sort_by { |k, _| k }.each do |year, hours_by_month_code|
  koko_vuoden_laskutettavat = 0
  koko_vuoden_tehdyt = 0
  vuodessa_tunteja = 0

  puts format(t(:year), year: year)

  hours_by_month_code.sort_by { |k, _| k }.each do |month, hours_by_code|
    laskutettavat = hours_by_code.select { |k, _| project_store.billable(k) }
    muut = hours_by_code.reject { |k, _| project_store.billable(k) }

    tehdyt_tunnit_yhteensä = hours_by_code.values.inject(:+) || 0
    laskutettavat_yhteensä = laskutettavat.values.inject(:+) || 0
    muut_yhteensä = muut.values.inject(:+) || 0

    first_day_of_month = Date.new(year, month, 1)
    last_day_of_month = Date.new(year, month, 1).next_month.prev_day

    # business_days_between calculates the days in a range which is open at the beginning: (from, to];
    # hence the first_day_of_month -1
    business_days = business_days_between(first_day_of_month - 1, [last_day_of_month, Date.today].min)
    holidays = $holiday_counter.for_month(year, month)
    workdays = business_days - holidays

    kuussa_tunteja_yhteensä = working_hours_per_day_for_year(year) * workdays

    koko_vuoden_laskutettavat += laskutettavat_yhteensä
    koko_vuoden_tehdyt += tehdyt_tunnit_yhteensä
    vuodessa_tunteja += kuussa_tunteja_yhteensä

    # Added a breakdown of days used in the calculations to help in bug spotting
    puts format(t(:month_info), month: $months[$lang][month - 1], year: year, business_days: business_days,
                                holidays: holidays, workdays: workdays)

    puts format(t(:month_total), done_hours: tehdyt_tunnit_yhteensä, hours_in_month: kuussa_tunteja_yhteensä)
    puts format(t(:billable), hours: laskutettavat_yhteensä,
                              ratio: perce(div(laskutettavat_yhteensä, kuussa_tunteja_yhteensä)))
    laskutettavat.nonzero_values_descending.each do |tuntikoodi, tunnit|
      puts format(t(:hours_per_code), hours: tunnit, code: tuntikoodi)
    end

    puts format(t(:non_billable), hours: muut_yhteensä, ratio: perce(div(muut_yhteensä, kuussa_tunteja_yhteensä)))

    muut.nonzero_values_descending.each do |tuntikoodi, tunnit|
      puts format(t(:hours_per_code), hours: tunnit, code: tuntikoodi)
    end
  end

  puts format(t(:year_total), year: year, hours_per_day: working_hours_per_day_for_year(year),
                              done_hours: koko_vuoden_tehdyt, hours_in_year: vuodessa_tunteja,
                              billable_in_year: koko_vuoden_laskutettavat,
                              billing_ratio: perce(div(koko_vuoden_laskutettavat, vuodessa_tunteja)))
end
