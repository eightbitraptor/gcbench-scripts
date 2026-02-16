#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'open3'

# Compare memory usage between two Ruby builds by running deterministic
# allocation scenarios and collecting heap/RSS metrics.
#
# Each scenario makes a fixed set of allocations, then the harness
# appends measurement code that dumps GC.stat, GC.stat_heap, RSS,
# and ObjectSpace.memsize_of_all via stderr KEY=VALUE lines.

SCENARIOS = {
  'small_objects' => {
    description: '2M small Objects — slot allocation overhead',
    code: <<~'RUBY'
      arr = Array.new(2_000_000) { Object.new }
    RUBY
  },
  'strings_varied' => {
    description: '500K strings of varied sizes — size pool behavior',
    code: <<~'RUBY'
      sizes = [0, 10, 23, 50, 100, 200, 500, 1000]
      arr = Array.new(500_000) { |i| "x" * sizes[i % sizes.length] }
    RUBY
  },
  'hashes' => {
    description: '200K hashes (1-20 keys each) — container overhead',
    code: <<~'RUBY'
      arr = Array.new(200_000) { |i|
        n = (i % 20) + 1
        h = {}
        n.times { |k| h[:"k#{k}"] = "v#{k}" }
        h
      }
    RUBY
  },
  'churn' => {
    description: 'Alloc/free/realloc — fragmentation & free list reuse',
    code: <<~'RUBY'
      arr = Array.new(1_000_000) { Object.new }
      (0...arr.length).step(2) { |i| arr[i] = nil }
      GC.start(full_mark: true, immediate_sweep: true)
      (0...arr.length).step(2) { |i| arr[i] = Object.new }
    RUBY
  },
  'peak_shrink' => {
    description: '2M alloc then release 75% — heap shrinking behavior',
    code: <<~'RUBY'
      arr = Array.new(2_000_000) { Object.new }
      GC.start(full_mark: true, immediate_sweep: true)
      (500_000...arr.length).each { |i| arr[i] = nil }
      3.times { GC.start(full_mark: true, immediate_sweep: true) }
      GC.compact if GC.respond_to?(:compact)
      GC.start(full_mark: true, immediate_sweep: true)
    RUBY
  },
}.freeze

# Appended to every scenario. Runs a final GC then dumps metrics.
REPORT_CODE = <<~'RUBY'
  require 'objspace'
  GC.start(full_mark: true, immediate_sweep: true)

  gc_stat = GC.stat
  gc_stat.each { |k, v| STDERR.puts "STAT_#{k.to_s.upcase}=#{v}" }

  begin
    GC.stat_heap.each do |pool_id, pool_stat|
      pool_stat.each { |k, v| STDERR.puts "POOL_#{pool_id}_#{k.to_s.upcase}=#{v}" }
    end
  rescue NoMethodError
  end

  rss = if File.exist?('/proc/self/status')
    File.read('/proc/self/status')[/VmRSS:\s*(\d+)/, 1].to_i
  else
    `ps -o rss= -p #{Process.pid}`.strip.to_i
  end
  STDERR.puts "RSS_KB=#{rss}"
  STDERR.puts "MEMSIZE_OF_ALL=#{ObjectSpace.memsize_of_all}"
RUBY

DEFAULT_RUNS = 11

def parse_report(stderr)
  report = { stat: {}, pools: {}, rss_kb: 0, memsize_of_all: 0 }

  stderr.each_line do |line|
    case line.strip
    when /\ASTAT_(\w+)=(-?\d+)\z/
      report[:stat][$1.downcase.to_sym] = $2.to_i
    when /\APOOL_(\d+)_(\w+)=(-?\d+)\z/
      pid = $1.to_i
      report[:pools][pid] ||= {}
      report[:pools][pid][$2.downcase.to_sym] = $3.to_i
    when /\ARSS_KB=(\d+)\z/
      report[:rss_kb] = $1.to_i
    when /\AMEMSIZE_OF_ALL=(\d+)\z/
      report[:memsize_of_all] = $1.to_i
    end
  end

  report
end

def median(values)
  return nil if values.empty?
  sorted = values.sort
  mid = sorted.length / 2
  sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

def median_report(reports)
  return nil if reports.empty?

  result = {
    rss_kb: median(reports.map { |r| r[:rss_kb] }),
    memsize_of_all: median(reports.map { |r| r[:memsize_of_all] }),
    stat: {},
    pools: {},
  }

  all_stat_keys = reports.flat_map { |r| r[:stat].keys }.uniq
  all_stat_keys.each do |key|
    vals = reports.map { |r| r[:stat][key] }.compact
    result[:stat][key] = median(vals) unless vals.empty?
  end

  all_pool_ids = reports.flat_map { |r| r[:pools].keys }.uniq.sort
  all_pool_ids.each do |pid|
    result[:pools][pid] = {}
    pool_keys = reports.flat_map { |r| (r[:pools][pid] || {}).keys }.uniq
    pool_keys.each do |key|
      vals = reports.map { |r| r.dig(:pools, pid, key) }.compact
      result[:pools][pid][key] = median(vals) unless vals.empty?
    end
  end

  result
end

def fmt_bytes(n, signed: false)
  return "\u2014" unless n
  prefix = signed && n > 0 ? '+' : ''
  abs = n.abs
  if abs >= 1_073_741_824
    "%s%.1f GB" % [prefix, n / 1_073_741_824.0]
  elsif abs >= 1_048_576
    "%s%.1f MB" % [prefix, n / 1_048_576.0]
  elsif abs >= 1024
    "%s%.1f KB" % [prefix, n / 1024.0]
  else
    "%s%d B" % [prefix, n]
  end
end

def fmt_kb(n, signed: false)
  fmt_bytes(n ? n * 1024 : nil, signed: signed)
end

def fmt_count(n, signed: false)
  return "\u2014" unless n
  v = n.is_a?(Float) ? n.round : n
  signed && v > 0 ? "+#{v}" : v.to_s
end

def pct_change(baseline, experiment)
  return nil unless baseline && experiment && baseline != 0
  (experiment - baseline).to_f / baseline * 100
end

def color_mem_pct(pct)
  return '' unless pct
  if pct < -0.05
    "\e[32m%+.1f%%\e[0m" % pct
  elsif pct > 0.05
    "\e[31m%+.1f%%\e[0m" % pct
  else
    "%+.1f%%" % pct
  end
end

class MemBenchRunner
  def initialize(baseline:, experiment:, runs:, verbose:, scenarios:)
    @baseline = baseline
    @experiment = experiment
    @runs = runs
    @verbose = verbose
    @scenarios = scenarios
  end

  def run_all
    validate_rubies!
    print_header

    results = {}
    @scenarios.each do |name, config|
      results[name] = run_scenario(name, config)
      puts
    end

    print_summary(results)
  end

  private

  def validate_rubies!
    [@baseline, @experiment].each do |ruby|
      abort "Ruby not found or not executable: #{ruby}" unless File.executable?(ruby)
    end
  end

  def ruby_version(path)
    Open3.capture2(path, '-v').first.strip
  rescue Errno::ENOENT
    '(unknown)'
  end

  def print_header
    bv = ruby_version(@baseline)
    ev = ruby_version(@experiment)

    puts '=' * 78
    puts 'Memory Allocation Benchmark'
    puts '=' * 78
    puts "Baseline:   #{@baseline}"
    puts "            #{bv}"
    puts "Experiment: #{@experiment}"
    puts "            #{ev}"
    puts "Runs:       #{@runs} (interleaved, median taken)"
    puts '=' * 78
    puts
  end

  def run_scenario(name, config)
    puts "#{name}: #{config[:description]}"
    puts "\u2500" * 60

    code = config[:code] + "\n" + REPORT_CODE
    print '  runs: '
    baseline_reports = []
    experiment_reports = []

    @runs.times do
      b = run_once(@baseline, code)
      baseline_reports << b if b
      print 'B'
      e = run_once(@experiment, code)
      experiment_reports << e if e
      print 'E'
    end
    puts

    if baseline_reports.empty? || experiment_reports.empty?
      puts "  \e[31mInsufficient data\e[0m"
      return nil
    end

    b = median_report(baseline_reports)
    e = median_report(experiment_reports)

    print_comparison(b, e)
    print_size_pools(b, e) if !b[:pools].empty? && !e[:pools].empty?

    if @verbose
      puts
      puts '  Raw RSS (KB):'
      puts "    baseline:   #{baseline_reports.map { |r| r[:rss_kb] }.join(', ')}"
      puts "    experiment: #{experiment_reports.map { |r| r[:rss_kb] }.join(', ')}"
    end

    { baseline: b, experiment: e }
  end

  def run_once(ruby_path, code)
    _, stderr, status = Open3.capture3(ruby_path, '--disable-gems', '-e', code)
    unless status.success?
      info = status.signaled? ? "signal #{status.termsig}" : "status #{status.exitstatus}"
      warn "  Warning: process exited (#{info})"
      return nil
    end
    parse_report(stderr)
  end

  def print_comparison(b, e)
    puts
    puts "  %-26s %12s %12s %12s %9s" % ['Metric', 'Baseline', 'Experiment', 'Delta', 'Change']
    puts "  #{'─' * 75}"

    print_row('RSS',              b[:rss_kb],                          e[:rss_kb],                          :kb)
    print_row('Heap Pages',       b[:stat][:heap_allocated_pages],     e[:stat][:heap_allocated_pages],     :count)
    print_row('Eden Pages',       b[:stat][:heap_eden_pages],          e[:stat][:heap_eden_pages],          :count)
    print_row('Tomb Pages',       b[:stat][:heap_tomb_pages],          e[:stat][:heap_tomb_pages],          :count)
    print_row('Live Slots',       b[:stat][:heap_live_slots],          e[:stat][:heap_live_slots],          :count)
    print_row('Free Slots',       b[:stat][:heap_free_slots],          e[:stat][:heap_free_slots],          :count)
    print_row('Total Alloc Pages', b[:stat][:total_allocated_pages],   e[:stat][:total_allocated_pages],    :count)
    print_row('Total Freed Pages', b[:stat][:total_freed_pages],       e[:stat][:total_freed_pages],        :count)
    print_row('Memsize (ObjSpace)', b[:memsize_of_all],               e[:memsize_of_all],                  :bytes)

    b_util = utilization(b)
    e_util = utilization(e)
    if b_util && e_util
      diff = e_util - b_util
      color = diff > 0.05 ? "\e[32m" : (diff < -0.05 ? "\e[31m" : "")
      reset = diff.abs > 0.05 ? "\e[0m" : ""
      puts "  %-26s %11.1f%% %11.1f%% %12s #{color}%+7.1fpp#{reset}" % [
        'Heap Utilization', b_util, e_util, '', diff
      ]
    end
  end

  def print_row(label, b_val, e_val, format)
    return unless b_val && e_val

    delta = e_val - b_val
    b_str, e_str, d_str = case format
    when :kb
      [fmt_kb(b_val), fmt_kb(e_val), fmt_kb(delta, signed: true)]
    when :bytes
      [fmt_bytes(b_val), fmt_bytes(e_val), fmt_bytes(delta, signed: true)]
    when :count
      [fmt_count(b_val), fmt_count(e_val), fmt_count(delta, signed: true)]
    end

    pct = pct_change(b_val, e_val)
    puts "  %-26s %12s %12s %12s %9s" % [label, b_str, e_str, d_str, color_mem_pct(pct)]
  end

  def print_size_pools(b, e)
    all_ids = (b[:pools].keys + e[:pools].keys).uniq.sort
    return if all_ids.empty?

    puts
    puts '  Size Pool Breakdown (eden/tomb pages):'
    puts "  %4s %7s │ %6s \u2192 %-6s %6s │ %6s \u2192 %-6s %6s" % [
      'Pool', 'SlotSz', 'Eden B', 'E', "\u0394", 'Tomb B', 'E', "\u0394"
    ]
    puts "  #{'─' * 66}"

    all_ids.each do |pid|
      bp = b[:pools][pid] || {}
      ep = e[:pools][pid] || {}
      slot_sz = bp[:slot_size] || ep[:slot_size] || 0

      b_eden = bp[:heap_eden_pages] || 0
      e_eden = ep[:heap_eden_pages] || 0
      b_tomb = bp[:heap_tomb_pages] || 0
      e_tomb = ep[:heap_tomb_pages] || 0

      eden_d = e_eden - b_eden
      tomb_d = e_tomb - b_tomb

      ec = eden_d < 0 ? "\e[32m" : (eden_d > 0 ? "\e[31m" : "")
      tc = tomb_d < 0 ? "\e[32m" : (tomb_d > 0 ? "\e[31m" : "")
      r = "\e[0m"

      puts "  %4d %6dB │ %6d \u2192 %-6d #{ec}%+5d#{r} │ %6d \u2192 %-6d #{tc}%+5d#{r}" % [
        pid, slot_sz, b_eden, e_eden, eden_d, b_tomb, e_tomb, tomb_d
      ]
    end
  end

  def utilization(report)
    live = report[:stat][:heap_live_slots]
    free = report[:stat][:heap_free_slots]
    return nil unless live && free && (live + free) > 0
    live.to_f / (live + free) * 100
  end

  def print_summary(results)
    puts '=' * 78
    puts 'Summary'
    puts '=' * 78
    puts

    puts "  %-16s \u2502 %12s %12s %12s %9s" % [
      'Scenario', 'RSS (B)', 'RSS (E)', 'Delta', 'Change'
    ]
    puts "  #{'─' * 66}"

    results.each do |name, data|
      next unless data
      b_rss = data[:baseline][:rss_kb]
      e_rss = data[:experiment][:rss_kb]
      delta = e_rss - b_rss
      pct = pct_change(b_rss, e_rss)

      puts "  %-16s \u2502 %12s %12s %12s %9s" % [
        name, fmt_kb(b_rss), fmt_kb(e_rss), fmt_kb(delta, signed: true), color_mem_pct(pct)
      ]
    end

    puts "  #{'─' * 66}"
    puts
    puts "  Positive change = experiment uses MORE memory (red)"
    puts "  Negative change = experiment uses LESS memory (green)"
    puts "  RSS via ps(1); heap metrics via GC.stat; memsize via ObjectSpace"
    puts "  Values are median of #{@runs} interleaved runs"
    puts
  end
end

def main
  options = { runs: DEFAULT_RUNS, verbose: false, scenarios: nil }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} --baseline=RUBY --experiment=RUBY [options]"

    opts.on('--baseline=PATH', 'Path to baseline Ruby binary') do |p|
      options[:baseline] = File.expand_path(p)
    end

    opts.on('--experiment=PATH', 'Path to experiment Ruby binary') do |p|
      options[:experiment] = File.expand_path(p)
    end

    opts.on('--runs=N', Integer, "Runs per scenario (default: #{DEFAULT_RUNS})") do |n|
      options[:runs] = n
    end

    opts.on('--scenario=NAME', 'Run specific scenario (repeatable)') do |name|
      (options[:scenarios] ||= []) << name
    end

    opts.on('-v', '--verbose', 'Show raw data per run') do
      options[:verbose] = true
    end

    opts.on('-h', '--help', 'Show this help') do
      puts opts
      exit
    end
  end

  parser.parse!

  unless options[:baseline] && options[:experiment]
    puts parser
    abort "\nError: Both --baseline and --experiment are required"
  end

  scenarios = if options[:scenarios]
    selected = {}
    options[:scenarios].each do |name|
      unless SCENARIOS.key?(name)
        abort "Unknown scenario: #{name}\nAvailable: #{SCENARIOS.keys.join(', ')}"
      end
      selected[name] = SCENARIOS[name]
    end
    selected
  else
    SCENARIOS
  end

  runner = MemBenchRunner.new(
    baseline: options[:baseline],
    experiment: options[:experiment],
    runs: options[:runs],
    verbose: options[:verbose],
    scenarios: scenarios,
  )
  runner.run_all
end

main
