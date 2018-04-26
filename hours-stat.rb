#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

require 'date'
require 'rexml/document'

months = %w(Tammi Helmi Maalis Huhti Touko Kesä Heinä Elo Syys Loka Marras Joulu).map { |m| "#{m}kuu" }

$hours_dir = "#{ENV['HOME']}/.hours"

class HolidayCount
  def key_for_date(d)
    "#{d.year}-#{d.month}"
  end

  def initialize
    @holidays_per_month = Hash.new(0)

    File.open("#{$hours_dir}/holidays.txt") do |f|
      while (line = f.gets) do
        d = Date.strptime(line.split(' ')[0], "%d.%m.%Y")
        if not d.saturday? and not d.sunday?
          @holidays_per_month[key_for_date(d)] += 1
        end
      end
    end
  end

  def for_month(year, month)
    @holidays_per_month[key_for_date(Date.new(year, month, 1))]
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
    @projects = File.open("#{$hours_dir}/projects.xml") do |f|
      x = REXML::Document.new(f.read)
      h = {}
      x.get_elements('//project').each { |e| h[e.attributes['name']] = (e.attributes['billable'] == 'true') }
      h
    end
  end

  def billable(tuntikoodi)
    project = tuntikoodi.split('-')[0]

    if not @projects.has_key? project
      $stderr.puts "*** Tuntematon projekti #{project}, oletetaan laskuttamaton".red
    end
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
  def nonzero_values_descending()
    self.sort_by { |k,v| v }.select { |k, v| v > 0.0 }.reverse
  end
end

def perce(f)
  "#{(f * 100).round(1)}"
end

def div(dividend, divisor)
  return divisor == 0 ? 0 : dividend / divisor
end

class HourStorage
  attr_reader :hours_by_year_month_code

  def initialize
    @hours_by_year_month_code = {}
  end

  def store_hours_for_date_code(d, code, hours)
    if not @hours_by_year_month_code.has_key? d.year
      @hours_by_year_month_code[d.year] = {}
    end

    if not @hours_by_year_month_code[d.year].has_key? d.month
      @hours_by_year_month_code[d.year][d.month] = Hash.new(0)
    end

    @hours_by_year_month_code[d.year][d.month][code] += hours
  end
end


hour_storage = HourStorage.new
holiday_counter = HolidayCount.new

Dir.entries($hours_dir).select { |e| e.match /[0-9]{4}_[0-9]{2}/ }.sort.each do |month|
  month_as_date = Date.strptime(month, '%Y_%m')

  month_dir = "#{$hours_dir}/#{month}"
  log_name = Dir.entries(month_dir).select { |e| e.match /^[a-z0-9]+\.txt/ }.first
  File.open("#{month_dir}/#{log_name}") do |f|
    while (line = f.gets) do
      next if line.match /^ *#/

      (_, tunnit, tuntikoodi, _) = line.split "\t"
      if !tunnit.nil?
        hour_storage.store_hours_for_date_code(month_as_date, tuntikoodi, tunnit.gsub(',', '.').to_f)
      end
    end
  end
end

hour_storage.hours_by_year_month_code.sort_by { |k,v| k }.each do |year, hours_by_month_code|
  koko_vuoden_laskutettavat = 0
  koko_vuoden_tehdyt = 0
  vuodessa_tunteja = 0

  puts "#### Vuosi #{year} #####"

  hours_by_month_code.sort_by { |k,v| k }.each do |month, hours_by_code|
    laskutettavat = hours_by_code.select { |k, v| project_store.billable(k) }
    muut = hours_by_code.select { |k, v| not project_store.billable(k) }

    tehdyt_tunnit_yhteensä = hours_by_code.values.inject(:+) || 0
    laskutettavat_yhteensä = laskutettavat.values.inject(:+) || 0
    muut_yhteensä = muut.values.inject(:+) || 0

    first_day_of_month = Date.new(year, month, 1)
    last_day_of_month = Date.new(year, month, 1).next_month.prev_day
    kuussa_tunteja_yhteensä = 7.5 * (business_days_between(first_day_of_month,
                                                               [last_day_of_month, Date.today].min) -
                                     holiday_counter.for_month(year, month))

    koko_vuoden_laskutettavat += laskutettavat_yhteensä
    koko_vuoden_tehdyt += tehdyt_tunnit_yhteensä
    vuodessa_tunteja += kuussa_tunteja_yhteensä

    puts "\n  ### #{months[month-1]} #{year}"

    puts "  Yhteensä #{tehdyt_tunnit_yhteensä} h kuukauden #{kuussa_tunteja_yhteensä} työtunnista joista"
    puts "    - laskutettavia #{laskutettavat_yhteensä} h, laskutusaste #{perce(div(laskutettavat_yhteensä, kuussa_tunteja_yhteensä))} %"
    laskutettavat.nonzero_values_descending.each do |tuntikoodi, tunnit|
      puts "       #{tunnit}\t#{tuntikoodi}"
    end

     puts "    - laskutettamattomia #{muut_yhteensä} h, laskuttamattomuusaste #{perce(div(muut_yhteensä, kuussa_tunteja_yhteensä))} %"
     muut.nonzero_values_descending.each do |tuntikoodi, tunnit|
       puts "       #{tunnit}\t#{tuntikoodi}"
    end
  end

  puts "\nVuonna #{year} yhteensä:\n#{koko_vuoden_tehdyt} h vuoden #{vuodessa_tunteja} työtunnista joista laskutettavia #{koko_vuoden_laskutettavat} h, laskutusaste #{perce(div(koko_vuoden_laskutettavat, vuodessa_tunteja))} %\n"
end

