#!/usr/bin/env ruby
# frozen_string_literal: true

RUBIES = {
  'master' => File.expand_path('~/.rubies/ruby-master-fast/bin/ruby'),
  'fast-sweep' => File.expand_path('~/.rubies/ruby-mvh-sizepool-powers-fast/bin/ruby')
}

BENCHMARK_CODE = <<~EOS
arr = []
10_000_000.times { 
  arr << Object.new
  arr << String.new("" * rand(100))
}
GC.start
EOS

WARMUP_RUNS = 1
BENCH_RUNS = 5

def run_benchmark(ruby_path)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  system(ruby_path, '--disable-gems', '--yjit', '-e', BENCHMARK_CODE, out: File::NULL, err: File::NULL)
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

results = {}

RUBIES.each do |name, path|
  puts `ruby -v`
  unless File.executable?(path)
    puts "#{name}: #{path} not found, skipping"
    next
  end

  puts "Benchmarking #{name}..."

  WARMUP_RUNS.times { run_benchmark(path) }

  times = BENCH_RUNS.times.map { run_benchmark(path) }
  results[name] = {
    min: times.min,
    max: times.max,
    mean: times.sum / times.size,
    times: times
  }

  puts "  times: #{times.map { |t| format('%.2fs', t) }.join(', ')}"
  puts "  mean:  #{format('%.2fs', results[name][:mean])}"

  puts GC.stat
end

if results.size == 2
  master = results['master'][:mean]
  fast_sweep = results['fast-sweep'][:mean]
  diff = ((master - fast_sweep) / master * 100)

  puts
  puts 'Summary:'
  puts "  master:     #{format('%.2fs', master)}"
  puts "  fast-sweep: #{format('%.2fs', fast_sweep)}"
  puts "  diff:       #{format('%+.1f%%', -diff)} (#{diff > 0 ? 'fast-sweep faster' : 'master faster'})"
end
