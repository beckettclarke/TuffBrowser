#!/usr/bin/env python3
"""Runs xcodebuild with a progress bar instead of its wall of text.

  scripts/xcbuild.py [--label "Debug build"] [--gen] [--tests] [--log FILE] -- xcodebuild ...

  --label   names the run in the header and in the history (default: "Build")
  --gen     runs `xcodegen generate` first, as a step of its own
  --tests   the run executes unit tests; progress also counts finished test cases
  --log     where the full xcodebuild output goes (default: build/<label>.log)

What the bar knows: Swift files compiled so far, out of the project's file count (or, once a full
run has finished, out of what that run compiled), and the time the last full run took. Both are
kept in build/.xcbuild-history.json. An incremental build compiles only a few files, so its bar
fills late and jumps to the end; a clean build is where it earns its keep.

Prints the warnings and errors once the run is over, plus the total time. Exits with xcodebuild's
status. Off a terminal (CI, pipes) it prints a line every 10% instead of redrawing the bar.
"""
import argparse
import atexit
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HISTORY = ROOT / "build" / ".xcbuild-history.json"

TTY = sys.stdout.isatty()
COLOR = TTY and "NO_COLOR" not in os.environ


def paint(code, text):
    return f"\033[{code}m{text}\033[0m" if COLOR else text


def bold(t): return paint("1", t)
def dim(t): return paint("2", t)
def red(t): return paint("31", t)
def green(t): return paint("32", t)
def yellow(t): return paint("33", t)
def cyan(t): return paint("36", t)


def duration(seconds):
    seconds = max(0, seconds)
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, rest = divmod(int(round(seconds)), 60)
    if minutes < 60:
        return f"{minutes}m {rest:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes:02d}m"


def short(path):
    try:
        return str(Path(path).relative_to(ROOT))
    except ValueError:
        return path


def load_history():
    try:
        return json.loads(HISTORY.read_text())
    except (OSError, ValueError):
        return {}


def save_history(history):
    try:
        HISTORY.parent.mkdir(parents=True, exist_ok=True)
        HISTORY.write_text(json.dumps(history, indent=1))
    except OSError:
        pass


# What xcodebuild prints for a task, by the task's name, and the words the bar shows for it.
ACTIVITY = [
    (("Resolve",), "Resolving"),
    (("SwiftExplicitDependency", "ClangStatCache", "ProcessPCH", "CreateBuildDirectory", "WriteAuxiliaryFile",
      "MkDir", "ExecuteExternalTool", "Prepare"), "Preparing"),
    (("SwiftDriver", "SwiftCompile", "SwiftEmitModule", "CompileSwift", "CompileC", "SwiftMergeGeneratedHeaders",
      "SwiftBuildModule"), "Compiling"),
    (("Ld", "Libtool", "CreateUniversalBinary", "GenerateDSYMFile", "ExtractAppIntentsMetadata"), "Linking"),
    (("CodeSign", "Validate", "RegisterExecutionPolicyException", "ProcessProductPackaging", "Touch"), "Signing"),
    (("CompileAssetCatalog", "LinkAssetCatalog", "GenerateAssetSymbols", "ProcessInfoPlistFile", "CopySwiftLibs",
      "Copy", "CpResource", "CompileStoryboard", "CompileXIB", "CopyPlistFile", "ProcessXCFramework"), "Bundling"),
]

TASK = re.compile(r"^([A-Z][A-Za-z]+) ")
SWIFT_BATCH = re.compile(r"^SwiftCompile \S+ \S+ Compiling\\ (.*?)(?<!\\) /")
DIAGNOSTIC = re.compile(r"^(?:(.+?):(\d+):(?:(\d+):)? )?(error|warning): (.*)$")
LD_DIAGNOSTIC = re.compile(r"^(ld|clang): (error|warning): (.*)$")
TEST_CASE = re.compile(r"^Test [Cc]ase '.*' (passed|failed)")
EXECUTED = re.compile(r"Executed (\d+) tests?")


def activity_for(task):
    for names, label in ACTIVITY:
        if any(task == n or task.startswith(n) for n in names):
            return label
    return None


def count_swift_files(tests):
    folders = ["TuffBrowser", "Vendor"] + (["TuffBrowserTests"] if tests else [])
    return sum(1 for folder in folders for _ in (ROOT / folder).rglob("*.swift"))


class Run:
    def __init__(self, args):
        self.label = args.label
        self.tests = args.tests
        self.start = time.time()
        self.lock = threading.Lock()
        self.history = load_history().get(self.label, {})
        self.expected_files = max(count_swift_files(args.tests), int(self.history.get("files", 0)))
        self.expected_tests = int(self.history.get("tests", 0))
        self.expected_seconds = float(self.history.get("seconds", 0))
        self.files = 0
        self.test_cases = 0
        self.executed = 0
        self.activity = "Starting"
        self.current = ""
        self.frac = 0.0
        self.diagnostics = {}      # (kind, text) -> location, in the order first seen
        self.result = None         # "succeeded" / "failed" once xcodebuild says so
        self.done = False
        self.width_drawn = 0
        self.last_decile = -1

    # -- progress ------------------------------------------------------------------------------

    def elapsed(self):
        return time.time() - self.start

    def update_fraction(self):
        files = min(self.files / self.expected_files, 1.0) if self.expected_files else 0.0
        # The compile is most of the wait; linking and signing get the rest.
        build = 0.93 * files
        if self.expected_seconds > 0:
            build = max(build, min(self.elapsed() / self.expected_seconds, 0.93))
        if self.tests:
            build *= 0.85
            if self.test_cases:
                tests = min(self.test_cases / self.expected_tests, 1.0) if self.expected_tests else 0.5
                build = 0.85 + 0.14 * tests
        self.frac = max(self.frac, min(build, 0.99))

    def counts(self):
        if self.tests and self.test_cases:
            total = f"/{self.expected_tests}" if self.expected_tests else ""
            return f"{self.test_cases}{total} tests"
        if self.files:
            return f"{self.files}/{max(self.expected_files, self.files)} files"
        return ""

    # -- reading xcodebuild --------------------------------------------------------------------

    def feed(self, line):
        with self.lock:
            self.parse(line)
            self.update_fraction()
            if not TTY:
                self.log_decile()

    def parse(self, line):
        batch = SWIFT_BATCH.match(line)
        if batch:
            names = batch.group(1).split(",\\ ")
            self.files += len(names)
            self.current = names[-1].replace("\\ ", " ")
            self.activity = "Compiling"
            return

        m = DIAGNOSTIC.match(line)
        if m:
            path, row, _, kind, text = m.groups()
            where = (short(path) + (f":{row}" if row else "")) if path else ""
            self.diagnostics.setdefault((kind, where, text), True)
            return
        m = LD_DIAGNOSTIC.match(line)
        if m:
            tool, kind, text = m.groups()
            self.diagnostics.setdefault((kind, tool, text), True)
            return

        case = TEST_CASE.match(line)
        if case:
            self.test_cases += 1
            self.activity = "Testing"
            self.current = re.sub(r"^Test [Cc]ase '(.*)'.*$", r"\1", line).replace("-[", "").replace("]", "")
            return
        ex = EXECUTED.search(line)
        if ex:
            self.executed = max(self.executed, int(ex.group(1)))
            return

        if line.startswith("** ") and line.rstrip().endswith("**"):
            self.result = "succeeded" if "SUCCEEDED" in line else "failed"
            return

        task = TASK.match(line)
        if task:
            label = activity_for(task.group(1))
            if label:
                self.activity = label
                if label != "Compiling":
                    self.current = ""

    # -- drawing -------------------------------------------------------------------------------

    def bar(self, width):
        filled = int(round(self.frac * width))
        return cyan("█" * filled) + dim("░" * (width - filled))

    def render(self, frame):
        # One line, never wider than the terminal: a wrapped line leaves its first row behind when
        # the next frame redraws only the last one.
        budget = shutil.get_terminal_size((100, 20)).columns - 1
        pct = f"{int(self.frac * 100):3d}%"
        left = ""
        if self.frac >= 0.05 and self.elapsed() > 5:
            left = f"~{duration(self.elapsed() * (1 - self.frac) / self.frac)} left"
        # In the order they are given up when the terminal is narrow.
        extras = [e for e in (duration(self.elapsed()), self.counts(), left) if e]
        fixed = 2 + 1 + 1 + 10 + 1 + 1 + len(pct)   # indent, spinner, activity, bar's spaces, percentage
        while extras and fixed + 10 + sum(len(e) + 2 for e in extras) > budget:
            extras.pop()
        room = budget - fixed - sum(len(e) + 2 for e in extras)
        width = max(min(24, room), 0)
        room -= width
        text = f"  {cyan(frame)} {bold(f'{self.activity:<10}')} {self.bar(width)} {pct}"
        text += "".join("  " + dim(e) for e in extras)
        if self.current and room > 10:
            current = self.current if len(self.current) <= room - 2 else self.current[: room - 3] + "…"
            text += "  " + dim(current)
        sys.stdout.write("\r\033[K" + text)
        sys.stdout.flush()

    def spin(self):
        frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
        i = 0
        while not self.done:
            with self.lock:
                self.update_fraction()
                self.render(frames[i % len(frames)])
            i += 1
            time.sleep(0.1)

    def say(self, text=""):
        """Prints a permanent line above the bar."""
        with self.lock:
            if TTY:
                sys.stdout.write("\r\033[K")
            print(text)
            sys.stdout.flush()

    def log_decile(self):
        decile = int(self.frac * 10)
        if decile > self.last_decile:
            self.last_decile = decile
            print(f"  [{decile * 10:3d}%] {self.activity} {self.counts()} ({duration(self.elapsed())})", flush=True)


def restore_cursor():
    if TTY:
        sys.stdout.write("\033[?25h")
        sys.stdout.flush()


def generate_project():
    started = time.time()
    if not shutil.which("xcodegen"):
        print(f"  {red('✗')} xcodegen is missing (brew install xcodegen)")
        sys.exit(1)
    result = subprocess.run(["xcodegen", "generate"], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True)
    if result.returncode != 0:
        print(f"  {red('✗')} Generating the Xcode project failed\n")
        print(result.stdout)
        sys.exit(result.returncode)
    print(f"  {green('✓')} Generated Xcode project  {dim(duration(time.time() - started))}")


def show_diagnostics(run, log_path):
    errors = [k for k in run.diagnostics if k[0] == "error"]
    warnings = [k for k in run.diagnostics if k[0] == "warning"]

    def show(key, mark):
        _, where, text = key
        print(f"  {mark} {where}" if where else f"  {mark}")
        print(f"      {text}")

    if errors:
        print()
        for key in errors:
            show(key, red("error"))
    if warnings:
        print()
        for key in warnings[:15]:
            show(key, yellow("warning"))
        if len(warnings) > 15:
            print(dim(f"  … and {len(warnings) - 15} more warnings in {short(str(log_path))}"))
    return len(errors), len(warnings)


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--label", default="Build")
    parser.add_argument("--gen", action="store_true")
    parser.add_argument("--tests", action="store_true")
    parser.add_argument("--log")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        sys.exit("usage: xcbuild.py [--label L] [--gen] [--tests] [--log FILE] -- xcodebuild ...")

    slug = re.sub(r"[^a-z0-9]+", "-", args.label.lower()).strip("-")
    log_path = Path(args.log) if args.log else ROOT / "build" / f"{slug}.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    os.chdir(ROOT)

    total_start = time.time()
    print(f"\n  {bold('Tuff')} {dim('·')} {args.label}\n")
    if args.gen:
        generate_project()

    run = Run(args)
    if TTY:
        sys.stdout.write("\033[?25l")
        atexit.register(restore_cursor)
    spinner = threading.Thread(target=run.spin, daemon=True) if TTY else None

    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                               errors="replace", bufsize=1)

    def interrupt(signum, frame):
        process.terminate()
        run.done = True
        run.say(f"\n  {yellow('■')} Cancelled after {duration(time.time() - total_start)}")
        sys.exit(130)

    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)

    if spinner:
        spinner.start()
    with open(log_path, "w") as log:
        for line in process.stdout:
            log.write(line)
            run.feed(line.rstrip("\n"))
    status = process.wait()
    run.done = True
    if spinner:
        spinner.join()
        sys.stdout.write("\r\033[K")
    restore_cursor()

    ok = status == 0 and run.result != "failed"
    seconds = time.time() - total_start
    errors, warnings = show_diagnostics(run, log_path)

    what = "Tests" if args.tests else "Build"
    notes = []
    if run.files:
        notes.append(f"{run.files} file{'s' if run.files != 1 else ''} compiled")
    if args.tests and (run.executed or run.test_cases):
        notes.append(f"{run.executed or run.test_cases} tests")
    if warnings:
        notes.append(f"{warnings} warning{'s' if warnings != 1 else ''}")
    if errors:
        notes.append(f"{errors} error{'s' if errors != 1 else ''}")
    summary = dim(" · ".join(notes))

    print()
    if ok:
        verb = "passed" if args.tests else "succeeded"
        print(f"  {green('✓')} {bold(f'{what} {verb}')}  {bold(duration(seconds))}  {summary}".rstrip())
    else:
        print(f"  {red('✗')} {bold(f'{what} failed')}  {bold(duration(seconds))}  {summary}".rstrip())
        if not errors:
            print(dim("\n  Last lines of the log:"))
            for line in log_path.read_text(errors="replace").splitlines()[-12:]:
                print(dim("    " + line))
        print(dim(f"\n  Full log: {short(str(log_path))}"))
    print()

    if ok:
        history = load_history()
        entry = history.get(args.label, {})
        # An incremental run compiles a handful of files; it would teach the bar the wrong size.
        if run.files >= 0.5 * max(entry.get("files", 0), 1):
            entry["files"] = run.files
            entry["seconds"] = round(run.elapsed(), 1)
        if args.tests and (run.executed or run.test_cases):
            entry["tests"] = run.executed or run.test_cases
        history[args.label] = entry
        save_history(history)
    sys.exit(0 if ok else (status or 1))


if __name__ == "__main__":
    main()
