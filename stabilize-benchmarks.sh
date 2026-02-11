#!/bin/bash
# stabilize-benchmarks.sh
# Run as root: sudo ./stabilize-benchmarks.sh [--restore]

set -e

usage() {
    echo "Usage: $0 [--restore]"
    echo "  (no args)   Stabilize system for benchmarking"
    echo "  --restore   Restore normal system behavior"
    exit 1
}

stabilize() {
    echo "=== Stabilizing system for benchmarking ==="

    # Disable turbo boost (Intel)
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo
        echo "Disabled Intel turbo boost"
    fi

    # Disable turbo boost (AMD)
    if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        echo 0 > /sys/devices/system/cpu/cpufreq/boost
        echo "Disabled AMD boost"
    fi

    # Set CPU governor to performance
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        if [ -f "$gov" ]; then
            echo performance > "$gov"
        fi
    done
    echo "Set CPU governor to performance"

    # Disable ASLR
    echo 0 > /proc/sys/kernel/randomize_va_space
    echo "Disabled ASLR"

    # Disable kernel samepage merging
    if [ -f /sys/kernel/mm/ksm/run ]; then
        echo 0 > /sys/kernel/mm/ksm/run
        echo "Disabled KSM"
    fi

    # Set scaling_min_freq to scaling_max_freq (lock CPU frequency)
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq; do
        if [ -f "$cpu/scaling_max_freq" ] && [ -f "$cpu/scaling_min_freq" ]; then
            cat "$cpu/scaling_max_freq" > "$cpu/scaling_min_freq"
        fi
    done
    echo "Locked CPU frequency"

    echo "=== Done ==="
    echo "Remember to run benchmarks with: taskset -c <cpu> to pin to a single core"
}

restore() {
    echo "=== Restoring normal system behavior ==="

    # Re-enable turbo boost (Intel)
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo
        echo "Enabled Intel turbo boost"
    fi

    # Re-enable turbo boost (AMD)
    if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        echo 1 > /sys/devices/system/cpu/cpufreq/boost
        echo "Enabled AMD boost"
    fi

    # Set CPU governor to schedutil (modern default) or ondemand as fallback
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        if [ -f "$gov" ]; then
            if grep -q schedutil "$(dirname "$gov")/scaling_available_governors" 2>/dev/null; then
                echo schedutil > "$gov"
            else
                echo ondemand > "$gov"
            fi
        fi
    done
    echo "Restored CPU governor to schedutil/ondemand"

    # Re-enable ASLR (2 = full randomization)
    echo 2 > /proc/sys/kernel/randomize_va_space
    echo "Enabled ASLR"

    # Re-enable kernel samepage merging
    if [ -f /sys/kernel/mm/ksm/run ]; then
        echo 1 > /sys/kernel/mm/ksm/run
        echo "Enabled KSM"
    fi

    # Restore scaling_min_freq from cpuinfo_min_freq
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq; do
        if [ -f "$cpu/cpuinfo_min_freq" ] && [ -f "$cpu/scaling_min_freq" ]; then
            cat "$cpu/cpuinfo_min_freq" > "$cpu/scaling_min_freq"
        fi
    done
    echo "Unlocked CPU frequency"

    echo "=== Done ==="
}

case "${1:-}" in
    "")
        stabilize
        ;;
    --restore|-r|restore)
        restore
        ;;
    *)
        usage
        ;;
esac
