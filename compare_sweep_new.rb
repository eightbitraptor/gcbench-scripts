#!/usr/bin/env ruby
# frozen_string_literal: true
RUBIES = {
  'master' => File.expand_path('~/.rubies/ruby-master-fast/bin/ruby'),
  'fast-sweep' => File.expand_path('~/.rubies/ruby-mvh-sweep-measure-fast/bin/ruby')
}
BENCHMARK_CODE = <<~'RUBY'
  10_000_000.times { Object.allocate; Object.allocate; Object.allocate; Object.allocate; Object.allocate; Object.allocate; Object.allocate; Object.allocate; Object.allocate; Object.allocate }
  stats = GC.stat
  STDERR.puts "GC: count=#{stats[:count]} time=#{stats[:time]}ms mark=#{stats[:marking_time]}ms sweep=#{stats[:sweeping_time]}ms"
RUBY
WARMUP_RUNS = 1
BENCH_RUNS = 5
def run_benchmark(ruby_path)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  system(ruby_path, '--disable-gems', '--yjit', '-e', BENCHMARK_CODE, out: File::NULL)
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end
results = {}
RUBIES.each do |name, path|
  unless File.executable?(path)
    puts "#{name}: #{path} not found, skipping"
    next
  end
  puts "Benchmarking #{name}..."
  puts `#{path} -v`
  WARMUP_RUNS.times { run_benchmark(path) }
  times = BENCH_RUNS.times.map { run_benchmark(path) }
  results[name] = {
    times: times,
    mean: times.sum / times.size
  }
  puts "  times: #{times.map { |t| format('%.2fs', t) }.join(', ')}"
  puts "  mean:  #{format('%.2fs', results[name][:mean])}"
  puts
end
if results.size == 2
  master = results['master'][:mean]
  fast_sweep = results['fast-sweep'][:mean]
  diff = ((master - fast_sweep) / master * 100)
  puts 'Summary:'
  puts "  master:     #{format('%.2fs', master)}"
  puts "  fast-sweep: #{format('%.2fs', fast_sweep)}"
  puts "  diff:       #{format('%+.1f%%', -diff)} (#{diff > 0 ? 'fast-sweep faster' : 'master faster'})"
end
