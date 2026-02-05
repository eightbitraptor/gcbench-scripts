#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare GC benchmark results between two Ruby builds
#
# Usage: ruby compare_gcbench.rb [benchmark_names...]
#        ruby compare_gcbench.rb              # runs all benchmarks
#        ruby compare_gcbench.rb hash1 rdoc   # runs specific benchmarks

BASELINE_RUBY = File.expand_path("~/.rubies/ruby-master-fast/bin/ruby")
EXPERIMENT_RUBY = File.expand_path("~/.rubies/ruby-mvh-sizepool-powers-fast/bin/ruby")
GCBENCH_DIR = File.expand_path("~/ruby/benchmark/gc")
GCBENCH_RUNNER = File.join(GCBENCH_DIR, "gcbench.rb")

BENCHMARKS = %w[null hash1 hash2 rdoc binary_trees ring redblack].freeze
RUNS_PER_BENCHMARK = 3

Result = Struct.new(:wallclock, :sweeping_time, :marking_time, :gc_count, keyword_init: true)

def run_benchmark(ruby_path, benchmark_name)
  cmd = [ruby_path, GCBENCH_RUNNER, "-q", benchmark_name]
  output = `#{cmd.shelljoin} 2>&1`
  unless $?.success?
    warn "Failed to run #{benchmark_name} with #{ruby_path}:\n#{output}"
    return nil
  end
  parse_output(output)
end

def parse_output(output)
  wallclock = nil
  sweeping_time = nil
  marking_time = nil
  gc_count = nil

  output.each_line do |line|
    case line
    when /\(\s*([\d.]+)\s*\)\s*$/
      wallclock = $1.to_f
    when /\bsweeping_time:\s*(\d+)/
      sweeping_time = $1.to_i
    when /\bmarking_time:\s*(\d+)/
      marking_time = $1.to_i
    when /\bcount:\s*(\d+)/
      gc_count = $1.to_i
    end
  end

  Result.new(
    wallclock: wallclock,
    sweeping_time: sweeping_time,
    marking_time: marking_time,
    gc_count: gc_count
  )
end

def median(values)
  sorted = values.compact.sort
  return nil if sorted.empty?
  mid = sorted.length / 2
  sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

def run_benchmark_with_warmup(ruby_path, benchmark_name, runs: RUNS_PER_BENCHMARK)
  results = runs.times.map do |i|
    $stderr.print "."
    run_benchmark(ruby_path, benchmark_name)
  end.compact
  return nil if results.empty?

  Result.new(
    wallclock: median(results.map(&:wallclock)),
    sweeping_time: median(results.map(&:sweeping_time)),
    marking_time: median(results.map(&:marking_time)),
    gc_count: median(results.map(&:gc_count))
  )
end

def speedup(baseline, experiment)
  return nil unless baseline && experiment && baseline > 0
  ((baseline - experiment) / baseline.to_f * 100).round(1)
end

def format_time_ms(ms)
  return "-" unless ms
  if ms >= 1000
    "%.2fs" % (ms / 1000.0)
  else
    "#{ms.to_i}ms"
  end
end

def format_time_s(s)
  return "-" unless s
  "%.3fs" % s
end

def format_speedup(pct)
  return "-" unless pct
  if pct > 0
    "\e[32m+#{pct}%\e[0m"
  elsif pct < 0
    "\e[31m#{pct}%\e[0m"
  else
    "0%"
  end
end

def print_header
  puts
  puts "=" * 100
  puts "GC Benchmark Comparison"
  puts "=" * 100
  puts "Baseline:   #{BASELINE_RUBY}"
  puts "Experiment: #{EXPERIMENT_RUBY}"
  puts "Runs per benchmark: #{RUNS_PER_BENCHMARK} (median taken)"
  puts "=" * 100
  puts
end

def print_table(results)
  header = "%-14s │ %10s %10s %8s │ %10s %10s %8s │ %8s %8s" % [
    "Benchmark", "Wall(B)", "Sweep(B)", "Mark(B)",
    "Wall(E)", "Sweep(E)", "Mark(E)",
    "Wall Δ", "Sweep Δ"
  ]
  separator = "─" * 14 + "─┼─" + "─" * 31 + "─┼─" + "─" * 31 + "─┼─" + "─" * 17

  puts header
  puts separator

  results.each do |name, baseline, experiment|
    wall_speedup = speedup(baseline&.wallclock, experiment&.wallclock)
    sweep_speedup = speedup(baseline&.sweeping_time, experiment&.sweeping_time)

    row = "%-14s │ %10s %10s %8s │ %10s %10s %8s │ %8s %8s" % [
      name,
      format_time_s(baseline&.wallclock),
      format_time_ms(baseline&.sweeping_time),
      format_time_ms(baseline&.marking_time),
      format_time_s(experiment&.wallclock),
      format_time_ms(experiment&.sweeping_time),
      format_time_ms(experiment&.marking_time),
      format_speedup(wall_speedup),
      format_speedup(sweep_speedup)
    ]
    puts row
  end
  puts separator
end

def main
  unless File.executable?(BASELINE_RUBY)
    abort "Baseline Ruby not found: #{BASELINE_RUBY}"
  end
  unless File.executable?(EXPERIMENT_RUBY)
    abort "Experiment Ruby not found: #{EXPERIMENT_RUBY}"
  end

  benchmarks = ARGV.empty? ? BENCHMARKS : ARGV
  benchmarks.each do |name|
    script = File.join(GCBENCH_DIR, "#{name}.rb")
    unless File.exist?(script)
      abort "Benchmark not found: #{script}"
    end
  end

  print_header

  results = []
  benchmarks.each do |name|
    $stderr.print "Running #{name}: "

    $stderr.print "baseline"
    baseline = run_benchmark_with_warmup(BASELINE_RUBY, name)

    $stderr.print " experiment"
    experiment = run_benchmark_with_warmup(EXPERIMENT_RUBY, name)

    $stderr.puts " done"
    results << [name, baseline, experiment]
  end

  print_table(results)

  puts
  puts "Legend: (B) = Baseline, (E) = Experiment, Δ = improvement (positive = faster)"
  puts "        Wall = total wallclock, Sweep = GC sweeping time, Mark = GC marking time"
  puts "        Times are median of #{RUNS_PER_BENCHMARK} runs"
  puts
end

require 'shellwords'
main
