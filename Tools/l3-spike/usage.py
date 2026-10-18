"""This process's resource use from proc_pid_rusage (RUSAGE_INFO_V6): footprint, peaks, CPU energy."""
import ctypes, os

class RUsageV6(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins",
        "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime", "ri_proc_exit_abstime",
        "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
        "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread", "ri_diskio_byteswritten",
        "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance", "ri_cpu_time_qos_background",
        "ri_cpu_time_qos_utility", "ri_cpu_time_qos_legacy", "ri_cpu_time_qos_user_initiated",
        "ri_cpu_time_qos_user_interactive", "ri_billed_system_time", "ri_serviced_system_time",
        "ri_logical_writes", "ri_lifetime_max_phys_footprint", "ri_instructions", "ri_cycles",
        "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint", "ri_runnable_time",
        "ri_flags", "ri_user_ptime", "ri_system_ptime", "ri_pinstructions", "ri_pcycles", "ri_energy_nj",
        "ri_penergy_nj", "ri_secure_time_in_system", "ri_secure_ptime_in_system", "ri_neural_footprint",
        "ri_lifetime_max_neural_footprint", "ri_interval_max_neural_footprint")] + [("ri_reserved", ctypes.c_uint64 * 9)]

_lib = ctypes.CDLL("/usr/lib/libproc.dylib")
_tb = ctypes.CDLL("/usr/lib/libSystem.dylib")

class _TB(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
_tbi = _TB(); _tb.mach_timebase_info(ctypes.byref(_tbi))

def usage(pid: int | None = None) -> dict:
    info = RUsageV6()
    if _lib.proc_pid_rusage(pid or os.getpid(), 6, ctypes.byref(info)) != 0:
        raise OSError("proc_pid_rusage")
    tick = _tbi.numer / _tbi.denom  # ns per tick
    mb = 1 / (1 << 20)
    return {
        "footprint_mb": info.ri_phys_footprint * mb,
        "peak_footprint_mb": info.ri_lifetime_max_phys_footprint * mb,
        "neural_mb": info.ri_neural_footprint * mb,
        "peak_neural_mb": info.ri_lifetime_max_neural_footprint * mb,
        "cpu_s": (info.ri_user_time + info.ri_system_time) * tick / 1e9,
        "cpu_energy_j": info.ri_energy_nj / 1e9,
    }

if __name__ == "__main__":
    x = 0
    for i in range(30_000_000): x += i
    print(usage())
