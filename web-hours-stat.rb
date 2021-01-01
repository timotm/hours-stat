#!/usr/bin/env ruby
# coding: utf-8
# frozen_string_literal: true

require 'date'
require 'net/http'
require 'json'
require 'optparse'

Encoding.default_external = Encoding::UTF_8

def get(client, path)
  api = '/api/v0'
  response = client.get("#{api}/#{path}",
                        { 'Cookie' => "__Secure-x-reaktor-session-id=#{$options[:session]}" })

  abort("Failed to get #{api}/#{path}: #{response.code} / #{response.body}") unless response.code.to_i == 200

  JSON.parse(response.body)
end

$options = {}
OptionParser.new do |opt|
  opt.on('--lang LANG', %i[fi en], 'Language (fi/en)') { |l| $options[:lang] = l }
  opt.on('--hours HOURS', Float, 'Number of working hours per day. If not given, guessed per year') do |h|
    $options[:hours_per_day] = h
  end
  opt.on('--session SESSION', String, 'Session cookie __Secure-x-* from browser') { |s| $options[:session] = s }
  opt.on('--server SERVER', String, 'Server, server.here') { |s| $options[:server] = s.gsub(%r{^.*://}, '') }
end.parse!

abort('ERROR: Missing session cookie') unless $options.key?(:session)
abort('ERROR: Missing server url') unless $options.key?(:server)

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
               fi: "\n  ### %{month} %{year}",
               en: "\n  ### %{month} %{year}"
             },
             month_total: {
               fi: '  Yhteensä %{done_hours} h kuukauden %{hours_in_month} työtunnista (%{diff}) joista',
               en: '  Total of %{done_hours} h out of %{hours_in_month} of the month (%{diff}), out of which'
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
               fi: "\nVuonna %{year} yhteensä:\n%{done_hours} h vuoden " \
                   '%{hours_in_year} työtunnista (%{diff}) joista laskutettavia %{billable_in_year} h, laskutusaste ' \
                   "%{billing_ratio} %\n",
               en: "\nYear %{year} total:\n%{done_hours} h out of " \
      '%{hours_in_year} hours of the year (%{diff}), out of which %{billable_in_year} h billable, billing ratio ' \
      "%{billing_ratio} %\n\n"
             } }

def t(key)
  $strings[key][$lang]
end

def billable?(code, billable_codes)
  project = code.split('-')[0]

  warn format(t(:unknown_project), project: project) unless billable_codes.key? project
  billable_codes[project] || false
end

def perce(f)
  (f * 100).round(1).to_s
end

def div(dividend, divisor)
  divisor.zero? ? 0 : dividend / divisor
end

def format_diff(d)
  sprintf("%+.1f", d)
end

class Hash
  def nonzero_values_descending
    sort_by { |_, v| v }.select { |_, v| v > 0.0 }.reverse
  end
end

client = Net::HTTP.new($options[:server], 443)
client.use_ssl = true

me = get(client, 'whoami')['username']
# me=ENV['USER']

codes = get(client, "codes/#{me}")
# codes=JSON.parse(File.read('codes.json'))
billable_codes = codes['invoices'].map { |e| [e['name'], e['billable']] }.to_h.merge('poissa' => false)

hours = get(client, "workMonths/#{me}")
# hours=JSON.parse(File.read('workMonths.json'))

(first_month, last_month) = hours.map { |m| m['month'] }.sort.values_at(0, -1)

summaries = get(client, "reports/monthSummaries/#{me}/#{first_month}/#{last_month}")
# summaries=JSON.parse(File.read('monthSummaries.json'))

expectedHours = summaries.transform_values { |v| v['requiredHours'] }

code_hour_pairs_by_month = hours
                           .map do |m|
  [m['month'],
   m['days'].map do |d|
     d['entries'].map { |e| [e['hourCode'], e['hours']] }
   end.flatten(1)]
end.to_h

summary_by_month = code_hour_pairs_by_month.transform_values do |hours|
  hours.each_with_object(Hash.new(0.0)) do |e, agg|
    agg[e[0]] += e[1].to_f
  end
end

months_by_year = summary_by_month.each_with_object({}) do |(yymm, value), agg|
  (y, m) = yymm.split('-')
  agg[y] = {} unless agg.key?(y)
  agg[y][m.to_i] = value
end

current_month = Time.now.strftime('%Y-%m')

months_by_year.sort_by { |k, _| k }.each do |year, codes_hours_by_month|
  billable_hours_for_year = 0
  all_hours_for_year = 0
  hours_in_year = 0

  puts format(t(:year), year: year)

  codes_hours_by_month.sort_by { |k, _| k }.each do |month, hours_by_code|
    this_month = "#{year}-#{'%02d' % month}"

    break if this_month > current_month

    billable_hours = hours_by_code.select { |k, _| billable?(k, billable_codes) }
    other_hours = hours_by_code.reject { |k, _| billable?(k, billable_codes) }

    all_hours_total = hours_by_code.values.inject(:+) || 0
    billable_hours_total = billable_hours.values.inject(:+) || 0
    other_hours_total = other_hours.values.inject(:+) || 0
    hours_in_this_month = expectedHours[this_month]

    billable_hours_for_year += billable_hours_total
    all_hours_for_year += all_hours_total
    hours_in_year += hours_in_this_month

    puts format(t(:month_info), month: $months[$lang][month - 1], year: year)
    puts format(t(:month_total), done_hours: all_hours_total, hours_in_month: hours_in_this_month, diff: format_diff(all_hours_total - hours_in_this_month))
    puts format(t(:billable), hours: billable_hours_total,
                              ratio: perce(div(billable_hours_total, hours_in_this_month)))
    billable_hours.nonzero_values_descending.each do |code, hours|
      puts format(t(:hours_per_code), hours: hours, code: code)
    end

    puts format(t(:non_billable), hours: other_hours_total, ratio: perce(div(other_hours_total, hours_in_this_month)))
    other_hours.nonzero_values_descending.each do |code, hours|
      puts format(t(:hours_per_code), hours: hours, code: code)
    end
  end

  puts format(t(:year_total), year: year,
                              done_hours: all_hours_for_year, hours_in_year: hours_in_year,
                              billable_in_year: billable_hours_for_year,
                              billing_ratio: perce(div(billable_hours_for_year, hours_in_year)),
                              diff: format_diff(all_hours_for_year - hours_in_year))
end
