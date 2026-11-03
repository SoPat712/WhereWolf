#!/usr/bin/env python3
"""Throttle an owned build/check when aggregate Mac CPU use exceeds its budget."""

import argparse
import ctypes
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


class CPU:
    def __init__(self):
        self.lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        self.lib.mach_host_self.restype = ctypes.c_uint
        self.lib.host_statistics.argtypes = [ctypes.c_uint, ctypes.c_int,
                                            ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        self.host = self.lib.mach_host_self()
        self.previous = self.ticks()

    def ticks(self):
        values = (ctypes.c_uint * 4)()
        count = ctypes.c_uint(4)
        if self.lib.host_statistics(self.host, 3, values, ctypes.byref(count)):
            raise RuntimeError('Cannot read CPU counters')
        return list(values)

    def busy(self):
        current = self.ticks()
        delta = [(b - a) & 0xffffffff for a, b in zip(self.previous, current)]
        self.previous = current
        return 100 * (sum(delta) - delta[2]) / max(1, sum(delta))


def processes():
    result = subprocess.run(['ps', '-axo', 'pid=,ppid=,lstart=,command='],
                            check=True, capture_output=True, text=True)
    rows = {}
    for line in result.stdout.splitlines():
        fields = line.split(None, 7)
        if len(fields) == 8:
            rows[int(fields[0])] = (int(fields[1]), ' '.join(fields[2:7]), fields[7])
    return rows


class OwnedProcesses:
    def __init__(self, child, roots, executables=(), simulator_pid=None):
        self.child = child
        self.roots = roots
        self.executables = executables
        self.known = {}
        self.terminable = {}
        self.stopped = {}
        self.simulator = None
        if simulator_pid:
            row = processes().get(simulator_pid)
            if not row or Path(row[2].split(' ', 1)[0]).name != 'launchd_sim':
                raise RuntimeError('Simulator PID must identify launchd_sim')
            self.simulator = (simulator_pid, row[1])

    def discover(self):
        rows = processes()
        owned = {self.child.pid}
        # Build workers launched through XPC have a different parent and process group.
        for pid, (_, started, command) in rows.items():
            if any(command == path or command.startswith(path + ' ') for path in self.executables):
                owned.add(pid)
            executable = Path(command.split(' ', 1)[0]).name
            if executable in {'clang', 'clang++', 'swift-frontend', 'swiftc', 'swift-driver',
                              'ld', 'ld-classic', 'ibtoold', 'ibtool', 'actool', 'metal',
                              'metallib', 'mapc', 'momc', 'intentbuilderc'}:
                if any(root in command for root in self.roots):
                    owned.add(pid)
            if self.terminable.get(pid) == started:
                owned.add(pid)
        def descendants(roots):
            result = set(roots)
            while True:
                children = {pid for pid, row in rows.items() if row[0] in result}
                if children <= result:
                    return result
                result |= children
        owned = descendants(owned)
        self.terminable = {pid: rows[pid][1] for pid in owned if pid in rows}
        if self.simulator:
            pid, started = self.simulator
            if pid in rows and rows[pid][1] == started:
                # Pause only this claimed device's processes; keep its launchd running.
                owned |= descendants({pid}) - {pid}
        owned.discard(os.getpid())
        self.known = {pid: rows[pid][1] for pid in owned if pid in rows}
        return rows

    @staticmethod
    def send(pid, sig):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass

    def pause(self):
        self.discover()
        for pid, started in sorted(self.known.items(), key=lambda item: item[0] != self.child.pid):
            self.send(pid, signal.SIGSTOP)
            self.stopped[pid] = started

    def resume(self):
        if self.stopped:
            rows = processes()
            for pid, started in self.stopped.items():
                if pid in rows and rows[pid][1] == started:
                    self.send(pid, signal.SIGCONT)
            self.stopped.clear()

    def terminate(self, signum):
        self.discover()
        self.resume()
        for pid in self.terminable:
            self.send(pid, signum)


def run(args):
    cpu = CPU()
    child = subprocess.Popen(args.command, start_new_session=True)
    try:
        owned = OwnedProcesses(child, args.work_root, getattr(args, 'process_path', []),
                               getattr(args, 'simulator_pid', None))
    except BaseException:
        child.terminate()
        child.wait()
        raise
    interrupted = None
    paused = False
    maximum = 0
    total = 0
    over_ceiling = 0
    samples = 0
    throttled = 0

    def forward(signum, frame):
        nonlocal interrupted
        interrupted = signum
        owned.terminate(signum)

    previous_handlers = {}
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous_handlers[sig] = signal.signal(sig, forward)
    print(f'CPU guard: pause at {args.target:g}%, resume below {args.resume:g}%; '
          '100 ms samples, owned processes only', flush=True)
    try:
        while child.poll() is None:
            time.sleep(0.1)
            busy = cpu.busy()
            maximum = max(maximum, busy)
            total += busy
            over_ceiling += busy > 80
            samples += 1
            if interrupted:
                continue
            if busy >= args.target and not paused:
                owned.pause()
                paused = True
                throttled += 1
            elif paused and busy < args.resume:
                owned.resume()
                paused = False
            elif paused:
                owned.pause()
            else:
                owned.discover()
        return -interrupted if interrupted else child.returncode
    except BaseException:
        owned.terminate(signal.SIGTERM)
        raise
    finally:
        owned.resume()
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
        print(f'CPU guard: {samples} samples, mean {total / max(1, samples):.1f}%, '
              f'peak {maximum:.1f}%, {over_ceiling} samples above 80%, '
              f'{throttled} throttle intervals', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', type=float, default=50)
    parser.add_argument('--resume', type=float, default=35)
    parser.add_argument('--work-root', action='append', default=[],
                        help='Unique DerivedData path for compiler workers launched through XPC')
    parser.add_argument('--process-path', action='append', default=[],
                        help='Exact executable path of this check\'s simulator app')
    parser.add_argument('--simulator-pid', type=int,
                        help='launchctl managerpid of the exclusively claimed simulator; '
                             'pause/resume its processes, never terminate them')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ['--']:
        args.command = args.command[1:]
    if not args.command or not 0 < args.resume < args.target <= 95:
        parser.error('Provide a command and 0 < resume < target <= 95')
    if any(not Path(root).is_absolute() or len(root) < 15 for root in args.work_root):
        parser.error('Work roots must be specific absolute DerivedData paths')
    if any(not Path(path).is_absolute() or len(path) < 15 for path in args.process_path):
        parser.error('Process paths must be specific absolute executable paths')
    sys.exit(run(args))


if __name__ == '__main__':
    main()
