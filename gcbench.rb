#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'open3'

# Benchmarks output GC phase times via stderr in KEY=VALUE format.
# We parse these to get isolated measurements of mark vs sweep.
BENCHMARKS = {
  'sweep' => {
    description: 'Sweeping performance (freeing dead objects)',
    primary_metric: :sweep_ms,
    code: <<~'RUBY'
      # Create objects that will all become garbage
      arr = Array.new(5_000_000) { Object.new }
      arr = nil  # All 5M objects now garbage

      # Measure the GC that frees them (no pre-GC - we want to measure sweep!)
      before = GC.stat
      GC.start(full_mark: true)
      after = GC.stat

      sweep_ms = after[:sweeping_time] - before[:sweeping_time]
      mark_ms = after[:marking_time] - before[:marking_time]
      STDERR.puts "SWEEP_MS=#{sweep_ms}"
      STDERR.puts "MARK_MS=#{mark_ms}"
      STDERR.puts "GC_COUNT=#{after[:count] - before[:count]}"
    RUBY
  },
  'mark' => {
    description: 'Marking performance (traversing live object graph)',
    primary_metric: :mark_ms,
    code: <<~'RUBY'
      # Deterministic object sizes
      srand(12345)
      arr = Array.new(5_000_000) { "x" * rand(100) }
      GC.start  # Ensure clean slate, objects promoted to old gen

      before = GC.stat
      GC.start(full_mark: true)
      after = GC.stat

      mark_ms = after[:marking_time] - before[:marking_time]
      sweep_ms = after[:sweeping_time] - before[:sweeping_time]
      STDERR.puts "MARK_MS=#{mark_ms}"
      STDERR.puts "SWEEP_MS=#{sweep_ms}"
      STDERR.puts "GC_COUNT=#{after[:count] - before[:count]}"
    RUBY
  }
}.freeze

WARMUP_RUNS = 1
DEFAULT_BENCH_RUNS = 5

BenchResult = Struct.new(:wall_time, :mark_ms, :sweep_ms, :gc_count, keyword_init: true)

module Stats
  module_function

  def mean(values)
    return nil if values.empty?
    values.sum.to_f / values.size
  end

  def median(values)
    return nil if values.empty?
    sorted = values.sort
    mid = sorted.length / 2
    sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  def stddev(values)
    return nil if values.size < 2
    m = mean(values)
    variance = values.sum { |v| (v - m) ** 2 } / (values.size - 1).to_f
    Math.sqrt(variance)
  end

  # t-distribution critical values for 95% confidence (two-tailed)
  T_CRITICAL_95 = {
    1 => 12.706, 2 => 4.303, 3 => 3.182, 4 => 2.776, 5 => 2.571,
    6 => 2.447, 7 => 2.365, 8 => 2.306, 9 => 2.262, 10 => 2.228,
    15 => 2.131, 20 => 2.086, 30 => 2.042, 60 => 2.000, 120 => 1.980
  }.freeze

  def t_critical(df)
    return T_CRITICAL_95[df] if T_CRITICAL_95.key?(df)
    keys = T_CRITICAL_95.keys.sort
    lower = keys.select { |k| k <= df }.max || keys.first
    upper = keys.select { |k| k >= df }.min || keys.last
    return T_CRITICAL_95[lower] if lower == upper
    t_low, t_high = T_CRITICAL_95[lower], T_CRITICAL_95[upper]
    t_low + (t_high - t_low) * (df - lower).to_f / (upper - lower)
  end

  # Welch's t-test for comparing two samples with potentially different variances
  def welch_t_test(sample1, sample2)
    n1, n2 = sample1.size, sample2.size
    return nil if n1 < 2 || n2 < 2

    m1, m2 = mean(sample1), mean(sample2)
    var1 = stddev(sample1) ** 2
    var2 = stddev(sample2) ** 2

    se = Math.sqrt(var1 / n1 + var2 / n2)
    return nil if se == 0

    mean_diff = m1 - m2
    t_stat = mean_diff / se

    # Welch-Satterthwaite degrees of freedom
    num = (var1 / n1 + var2 / n2) ** 2
    denom = ((var1 / n1) ** 2 / (n1 - 1)) + ((var2 / n2) ** 2 / (n2 - 1))
    df = [num / denom, 1].max.floor

    t_crit = t_critical(df)
    margin = t_crit * se

    {
      t_stat: t_stat,
      df: df,
      significant: t_stat.abs > t_crit,
      mean_diff: mean_diff,
      ci_low: mean_diff - margin,
      ci_high: mean_diff + margin,
      speedup_pct: m1.zero? ? 0.0 : (mean_diff / m1 * 100),
      baseline_mean: m1,
      experiment_mean: m2
    }
  end
end

class BenchmarkRunner
  def initialize(baseline:, experiment:, runs:, verbose:)
    @baseline = baseline
    @experiment = experiment
    @runs = runs
    @verbose = verbose
  end

  def run_all
    validate_rubies!

    puts header
    puts

    results = {}
    BENCHMARKS.each do |name, config|
      results[name] = run_benchmark(name, config)
      puts
    end

    print_summary(results)
  end

  private

  def validate_rubies!
    [@baseline, @experiment].each do |ruby|
      unless File.executable?(ruby)
        abort "Ruby not found or not executable: #{ruby}"
      end
    end
  end

  def ruby_version(path)
    stdout, = Open3.capture2(path, '-v')
    stdout.strip
  rescue Errno::ENOENT
    '(unknown)'
  end

  def header
    baseline_version = ruby_version(@baseline)
    experiment_version = ruby_version(@experiment)

    <<~HEADER
      #{'=' * 80}
      GC Benchmark Comparison
      #{'=' * 80}
      Baseline:   #{@baseline}
                  #{baseline_version}
      Experiment: #{@experiment}
                  #{experiment_version}
      Runs:       #{@runs} (+ #{WARMUP_RUNS} warmup, interleaved)
      #{'=' * 80}
    HEADER
  end

  def run_benchmark(name, config)
    puts "#{name}: #{config[:description]}"
    puts '-' * 60

    # Warmup both rubies
    print "  warmup: "
    WARMUP_RUNS.times do
      run_once(@baseline, config[:code])
      print 'B'
      run_once(@experiment, config[:code])
      print 'E'
    end
    puts

    # Interleaved benchmark runs to reduce systematic bias
    print "  measuring: "
    baseline_results = []
    experiment_results = []

    @runs.times do
      baseline_results << run_once(@baseline, config[:code])
      print 'B'
      experiment_results << run_once(@experiment, config[:code])
      print 'E'
    end
    puts

    print_benchmark_results(config, baseline_results, experiment_results)

    { baseline: baseline_results, experiment: experiment_results, config: config }
  end

  def run_once(ruby_path, code)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout, stderr, status = Open3.capture3(
      ruby_path, '--disable-gems', '--yjit', '-e', code
    )
    wall_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    unless status.success?
      warn "Warning: benchmark exited with error: #{stderr}"
    end

    # Parse GC stats from stderr
    mark_ms = extract_value(stderr, 'MARK_MS')
    sweep_ms = extract_value(stderr, 'SWEEP_MS')
    gc_count = extract_value(stderr, 'GC_COUNT')

    BenchResult.new(
      wall_time: wall_time,
      mark_ms: mark_ms,
      sweep_ms: sweep_ms,
      gc_count: gc_count
    )
  end

  def extract_value(output, key)
    output[/^#{Regexp.escape(key)}=(\d+)/, 1]&.to_i
  end

  def extract_times(results, metric)
    times = results.map(&metric).compact
    return times unless times.empty?

    warn "  Warning: Could not extract #{metric}, falling back to wall-clock"
    results.map { |r| r.wall_time * 1000 }
  end

  def print_benchmark_results(config, baseline_results, experiment_results)
    metric = config[:primary_metric]
    baseline_times = extract_times(baseline_results, metric)
    experiment_times = extract_times(experiment_results, metric)

    puts
    puts "  #{metric}:"
    puts "  %-12s %10s %10s %10s" % ['', 'mean', 'median', 'stddev']
    puts "  #{'-' * 44}"

    [['baseline', baseline_times], ['experiment', experiment_times]].each do |label, times|
      puts "  %-12s %9.1fms %9.1fms %9.2fms" % [
        label,
        Stats.mean(times),
        Stats.median(times),
        Stats.stddev(times) || 0
      ]
    end

    if @verbose
      puts
      puts "  baseline raw:   #{baseline_times.map { |t| "#{t.round(1)}ms" }.join(', ')}"
      puts "  experiment raw: #{experiment_times.map { |t| "#{t.round(1)}ms" }.join(', ')}"
    end

    comparison = Stats.welch_t_test(baseline_times, experiment_times)
    print_comparison(comparison) if comparison
  end

  def print_comparison(comparison)
    puts
    speedup = comparison[:speedup_pct]
    direction = speedup > 0 ? 'faster' : 'slower'
    color = speedup > 0 ? "\e[32m" : "\e[31m"
    reset = "\e[0m"
    sig_marker = comparison[:significant] ? '*' : ''

    puts "  Difference: #{color}%+.2f%%%s#{reset} (experiment #{direction})" % [speedup, sig_marker]
    puts "  95%% CI:     [%+.2fms, %+.2fms]" % [comparison[:ci_low], comparison[:ci_high]]
    puts "  t-stat:     %.3f (df=%d)" % [comparison[:t_stat], comparison[:df]]

    unless comparison[:significant]
      puts "  \e[33m(not statistically significant at p<0.05)\e[0m"
    end
  end

  def print_summary(results)
    puts '=' * 80
    puts 'Summary'
    puts '=' * 80
    puts

    rows = results.map do |name, data|
      metric = data[:config][:primary_metric]
      baseline_times = extract_times(data[:baseline], metric)
      experiment_times = extract_times(data[:experiment], metric)
      comparison = Stats.welch_t_test(baseline_times, experiment_times)

      [name, baseline_times, experiment_times, comparison]
    end

    puts "%-10s │ %12s │ %12s │ %10s │ %s" % [
      'Benchmark', 'Baseline', 'Experiment', 'Change', 'Significance'
    ]
    puts '─' * 75

    rows.each do |name, baseline_times, experiment_times, comparison|
      baseline_mean = Stats.mean(baseline_times)
      experiment_mean = Stats.mean(experiment_times)
      speedup = comparison&.fetch(:speedup_pct) ||
                (baseline_mean.zero? ? 0.0 : ((baseline_mean - experiment_mean) / baseline_mean * 100))
      sig = comparison&.fetch(:significant)

      color = speedup > 0 ? "\e[32m" : (speedup < 0 ? "\e[31m" : "")
      reset = speedup != 0 ? "\e[0m" : ""

      puts "%-10s │ %10.1fms │ %10.1fms │ #{color}%+9.2f%%#{reset} │ %s" % [
        name,
        baseline_mean,
        experiment_mean,
        speedup,
        sig ? 'p < 0.05 **' : 'not significant'
      ]
    end

    puts '─' * 75
    puts
    puts "** = statistically significant at 95% confidence level"
    puts "Positive change = experiment is faster than baseline"
    puts "Times shown are GC phase times from GC.stat, not wall-clock"
    puts
  end
end

def main
  options = {
    runs: DEFAULT_BENCH_RUNS,
    verbose: false
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} --baseline=RUBY --experiment=RUBY [options]"

    opts.on('--baseline=PATH', 'Path to baseline Ruby binary') do |path|
      options[:baseline] = File.expand_path(path)
    end

    opts.on('--experiment=PATH', 'Path to experiment Ruby binary') do |path|
      options[:experiment] = File.expand_path(path)
    end

    opts.on('--runs=N', Integer, "Number of benchmark runs (default: #{DEFAULT_BENCH_RUNS})") do |n|
      options[:runs] = n
    end

    opts.on('-v', '--verbose', 'Show raw timing data') do
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

  runner = BenchmarkRunner.new(
    baseline: options[:baseline],
    experiment: options[:experiment],
    runs: options[:runs],
    verbose: options[:verbose]
  )
  runner.run_all
end

main
