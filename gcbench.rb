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
      arr = Array.new(5_000_000) { Object.new }

      # Flush any pending lazy sweeps from allocation-triggered GCs
      GC.start(full_mark: true, immediate_sweep: true)

      arr = nil  # All 5M objects now garbage

      before = GC.stat
      GC.start(full_mark: true, immediate_sweep: true)
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
      srand(12345)
      nodes = Array.new(5_000_000) { [nil, nil] }
      nodes.each_with_index do |node, i|
        node[0] = nodes[rand(i + 1)]
        node[1] = nodes[rand(i + 1)] if i > 0
      end

      # Promote to old gen (RVALUE_OLD_AGE=3, need 3 cycles)
      3.times { GC.start(full_mark: true, immediate_sweep: true) }

      before = GC.stat
      GC.start(full_mark: true, immediate_sweep: true)
      after = GC.stat

      mark_ms = after[:marking_time] - before[:marking_time]
      sweep_ms = after[:sweeping_time] - before[:sweeping_time]
      STDERR.puts "MARK_MS=#{mark_ms}"
      STDERR.puts "SWEEP_MS=#{sweep_ms}"
      STDERR.puts "GC_COUNT=#{after[:count] - before[:count]}"
    RUBY
  }
}.freeze

WARMUP_RUNS = 2
DEFAULT_BENCH_RUNS = 10

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

  # Median absolute deviation — robust spread estimator
  def mad(values)
    return nil if values.empty?
    med = median(values)
    deviations = values.map { |v| (v - med).abs }
    median(deviations)
  end

  # Flag observations > threshold MADs from median
  def outlier_indices(values, threshold: 3.0)
    return [] if values.size < 3
    med = median(values)
    m = mad(values)
    return [] if m.nil? || m == 0
    values.each_index.select { |i| (values[i] - med).abs > threshold * m }
  end

  # Bootstrap CI on percentage change relative to baseline (non-parametric)
  def bootstrap_pct_ci(sample1, sample2, n_boot: 10_000, alpha: 0.05)
    rng = Random.new(54321)
    n1, n2 = sample1.size, sample2.size
    pcts = Array.new(n_boot) do
      s1 = Array.new(n1) { sample1[rng.rand(n1)] }
      s2 = Array.new(n2) { sample2[rng.rand(n2)] }
      m1 = mean(s1)
      m1.zero? ? 0.0 : ((m1 - mean(s2)) / m1 * 100)
    end
    pcts.sort!
    lo = (n_boot * alpha / 2).floor
    hi = (n_boot * (1 - alpha / 2)).floor
    { ci_low: pcts[lo], ci_high: pcts[hi], median_pct: pcts[n_boot / 2] }
  end

  # Glass's delta — effect size using baseline stddev as denominator.
  # Preferred over pooled Cohen's d when variances may differ (Welch scenario).
  def glass_delta(baseline, experiment)
    return nil if baseline.size < 2 || experiment.size < 2
    s = stddev(baseline)
    return nil if s == 0
    (mean(baseline) - mean(experiment)) / s
  end

  def effect_size_label(d)
    return "negligible" if d.nil?
    case d.abs
    when 0...0.2 then "negligible"
    when 0.2...0.5 then "small"
    when 0.5...0.8 then "medium"
    else "large"
    end
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
      ruby_path, '--disable-gems', '-e', code
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
    puts "  %-12s %10s %10s %10s %10s" % ['', 'mean', 'median', 'stddev', 'MAD']
    puts "  #{'-' * 56}"

    [['baseline', baseline_times], ['experiment', experiment_times]].each do |label, times|
      outliers = Stats.outlier_indices(times)
      outlier_mark = outliers.empty? ? '' : " (#{outliers.size} outlier#{'s' if outliers.size > 1})"
      puts "  %-12s %9.1fms %9.1fms %9.2fms %9.2fms%s" % [
        label,
        Stats.mean(times),
        Stats.median(times),
        Stats.stddev(times) || 0,
        Stats.mad(times) || 0,
        outlier_mark
      ]
    end

    if @verbose
      puts
      [['baseline', baseline_times], ['experiment', experiment_times]].each do |label, times|
        outliers = Stats.outlier_indices(times)
        tagged = times.each_with_index.map do |t, i|
          outliers.include?(i) ? "\e[33m#{t.round(1)}ms!\e[0m" : "#{t.round(1)}ms"
        end
        puts "  #{label} raw: #{tagged.join(', ')}"
      end
    end

    comparison = Stats.welch_t_test(baseline_times, experiment_times)
    print_comparison(baseline_times, experiment_times, comparison) if comparison
  end

  def print_comparison(baseline_times, experiment_times, comparison)
    puts
    speedup = comparison[:speedup_pct]
    direction = speedup > 0 ? 'faster' : 'slower'
    color = speedup > 0 ? "\e[32m" : "\e[31m"
    reset = "\e[0m"
    sig_marker = comparison[:significant] ? '*' : ''

    puts "  Difference: #{color}%+.2f%%%s#{reset} (experiment is #{direction})" % [speedup, sig_marker]

    # Welch's t-test CI (absolute)
    puts "  Welch 95%% CI: [%+.1fms, %+.1fms]" % [comparison[:ci_low], comparison[:ci_high]]
    puts "  t-stat:        %.3f (df=%d)" % [comparison[:t_stat], comparison[:df]]

    # Bootstrap CI (percentage)
    boot_pct = Stats.bootstrap_pct_ci(baseline_times, experiment_times)
    puts "  Boot 95%% CI:  [%+.2f%%, %+.2f%%]" % [boot_pct[:ci_low], boot_pct[:ci_high]]

    # Effect size (Glass's delta — uses baseline stddev as reference)
    d = Stats.glass_delta(baseline_times, experiment_times)
    if d
      label = Stats.effect_size_label(d)
      puts "  Effect size:   %.3f (%s)" % [d, label]
    end

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
      boot = Stats.bootstrap_pct_ci(baseline_times, experiment_times)

      [name, baseline_times, experiment_times, comparison, boot]
    end

    puts "%-10s │ %12s │ %12s │ %10s │ %18s │ %s" % [
      'Benchmark', 'Baseline', 'Experiment', 'Change', 'Boot 95% CI', 'Significance'
    ]
    puts '─' * 90

    rows.each do |name, baseline_times, experiment_times, comparison, boot|
      baseline_mean = Stats.mean(baseline_times)
      experiment_mean = Stats.mean(experiment_times)
      speedup = comparison&.fetch(:speedup_pct) ||
                (baseline_mean.zero? ? 0.0 : ((baseline_mean - experiment_mean) / baseline_mean * 100))
      sig = comparison&.fetch(:significant)

      color = speedup > 0 ? "\e[32m" : (speedup < 0 ? "\e[31m" : "")
      reset = speedup != 0 ? "\e[0m" : ""

      boot_ci = "[%+.1f%%, %+.1f%%]" % [boot[:ci_low], boot[:ci_high]]

      puts "%-10s │ %10.1fms │ %10.1fms │ #{color}%+9.2f%%#{reset} │ %18s │ %s" % [
        name,
        baseline_mean,
        experiment_mean,
        speedup,
        boot_ci,
        sig ? 'p < 0.05 **' : 'not significant'
      ]
    end

    puts '─' * 90
    puts
    puts "** = statistically significant at 95% confidence level (Welch's t-test)"
    puts "Positive change = experiment is faster than baseline"
    puts "Times are GC phase CPU time from GC.stat; summary shows means"
    puts "Per-benchmark details include median + MAD for robustness"
    puts "With default settings (10 runs, 5M objects): reliably detects ~5% differences"
    puts "For smaller effects, use --runs=20 or higher"
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
