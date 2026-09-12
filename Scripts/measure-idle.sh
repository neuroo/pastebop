#!/usr/bin/env bash
#
# measure-idle.sh -- what the running app costs while nothing is happening.
#
#     Scripts/measure-idle.sh [seconds]      (default 60)
#
# Reads the kernel's per-process accounting through proc_pid_rusage, the same
# source Activity Monitor's Energy tab draws on. Every figure is charged to
# this one process, so the numbers hold on a busy development Mac -- unlike
# top's IDLEW, which counts wakeups *from package idle* and reads zero for
# everything the moment anything else keeps the CPU awake.
#
# Interrupt wakeups are the timer fires: with a 100 ms poll expect about ten a
# second. CPU time, cycles and instructions are the work those fires did.
# Billed energy is accounted in coarse quanta; a zero over a short window
# means "below one quantum", not zero.
#
set -euo pipefail

SECONDS_TO_SAMPLE="${1:-60}"
PID="$(pgrep -x PasteBop | head -1 || true)"
[[ -n "$PID" ]] || { echo "PasteBop is not running" >&2; exit 1; }

TOOL="${TMPDIR:-/tmp}/pastebop-rusage"
if [[ ! -x "$TOOL" ]]; then
	clang -O2 -o "$TOOL" -x c - <<'C'
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>

int main(int argc, char **argv) {
	if (argc != 3) { fprintf(stderr, "usage: %s pid seconds\n", argv[0]); return 2; }
	pid_t pid = (pid_t)atoi(argv[1]);
	unsigned seconds = (unsigned)atoi(argv[2]);
	struct rusage_info_v4 before, after;
	if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&before) != 0) { perror("proc_pid_rusage"); return 1; }
	sleep(seconds);
	if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&after) != 0) { perror("proc_pid_rusage"); return 1; }
	/* On Apple silicon the time fields are nanoseconds. */
	unsigned long long cpu_ns = (after.ri_user_time - before.ri_user_time)
	                          + (after.ri_system_time - before.ri_system_time);
	printf("%llu %llu %llu %llu %llu %llu\n", cpu_ns,
	       (unsigned long long)(after.ri_interrupt_wkups - before.ri_interrupt_wkups),
	       (unsigned long long)(after.ri_pkg_idle_wkups - before.ri_pkg_idle_wkups),
	       (unsigned long long)(after.ri_cycles - before.ri_cycles),
	       (unsigned long long)(after.ri_instructions - before.ri_instructions),
	       (unsigned long long)(after.ri_billed_energy - before.ri_billed_energy));
	return 0;
}
C
fi

read -r CPU_NS INTERRUPT_WAKEUPS IDLE_WAKEUPS CYCLES INSTRUCTIONS ENERGY_NJ \
	< <("$TOOL" "$PID" "$SECONDS_TO_SAMPLE")

per_second() { echo "$1 / $SECONDS_TO_SAMPLE" | bc -l; }

printf 'PasteBop (pid %s), %ss idle:\n' "$PID" "$SECONDS_TO_SAMPLE"
printf '  timer fires    %8d      %6.1f/s  (interrupt wakeups)\n' \
	"$INTERRUPT_WAKEUPS" "$(per_second "$INTERRUPT_WAKEUPS")"
printf '  cpu time       %8.2f ms   %6.4f%% of one core\n' \
	"$(echo "$CPU_NS / 1000000" | bc -l)" "$(echo "$CPU_NS / ($SECONDS_TO_SAMPLE * 10000000)" | bc -l)"
printf '  cycles         %8.2f M    %6.2f M/s\n' \
	"$(echo "$CYCLES / 1000000" | bc -l)" "$(per_second "$(echo "$CYCLES / 1000000" | bc -l)")"
printf '  instructions   %8.2f M    %6.2f M/s\n' \
	"$(echo "$INSTRUCTIONS / 1000000" | bc -l)" "$(per_second "$(echo "$INSTRUCTIONS / 1000000" | bc -l)")"
printf '  billed energy  %8.2f mJ   %6.3f mW\n' \
	"$(echo "$ENERGY_NJ / 1000000" | bc -l)" "$(per_second "$(echo "$ENERGY_NJ / 1000000" | bc -l)")"
printf '  idle wakeups   %8d      (package-idle only; 0 on a busy machine)\n' "$IDLE_WAKEUPS"
