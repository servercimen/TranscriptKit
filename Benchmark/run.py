#!/usr/bin/env python3
"""Runs the TranscriptBench app once per renderer and scenario and tabulates the results.

Usage:
    python3 Benchmark/run.py --device <simulator UDID> [--repeats 3] [--build]
    python3 Benchmark/run.py --device <iPhone UDID> --physical --team <team ID> --out results-device --build

Each run is a fresh launch of the app, which prints one BENCH_RESULT line and exits.
Results are written to Benchmark/results/results.json and summarised in
Benchmark/results/RESULTS.md.
"""
import argparse
import json
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUNDLE = "dev.transcriptkit.bench"
APP = os.path.join(ROOT, ".build/bench/Build/Products/Debug-iphonesimulator/TranscriptBench.app")

# "none" streams into nothing: the harness's own cost, to subtract when reading the others.
RENDERERS = ["none", "transcriptkit", "transcriptkit-stream", "transcriptkit-uikit", "textual", "textual-noselect", "webview"]
SCENARIOS = [
    # name, characters, characters per second, earlier messages, ms between updates
    ("single", 6000, 300, 0, 4),
    ("history", 6000, 300, 50, 4),
    ("burst", 20000, 2000, 0, 4),
    ("realistic", 6000, 300, 50, 33),
    # Scrolls up and down through 50 earlier messages at 3000 points/s for 10 s, without streaming.
    ("scroll", 0, 300, 50, 4),
    # The same with Corpus.richSection: tables, task lists, nested quotes, reference links whose
    # definitions come later, emails, entities, a little HTML and images (added 2026-11-16).
    ("rich-history", 6000, 300, 50, 4, "rich"),
    ("rich-burst", 20000, 2000, 0, 4, "rich"),
    ("rich-scroll", 0, 300, 50, 4, "rich"),
]


def unpack(scenario):
    """name, characters, rate, history, interval, corpus"""
    return tuple(scenario[:5]) + ((scenario[5] if len(scenario) > 5 else "answer"),)


# Extra launch arguments for every run, from --app-args.
EXTRA_ARGUMENTS = []

DEVICE_APP = os.path.join(ROOT, ".build/bench-device/Build/Products/Debug-iphoneos/TranscriptBench.app")


def build(device, physical, team, promotion=False):
    # Command-line settings apply to the Swift packages too. Without them Xcode
    # builds TranscriptKit and Textual unoptimised in this configuration.
    command = ["xcodebuild", "build", "-project", "TranscriptBench.xcodeproj", "-scheme", "TranscriptBench", "-quiet",
               "SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule", "GCC_OPTIMIZATION_LEVEL=s",
               "ENABLE_TESTABILITY=NO", "SWIFT_ACTIVE_COMPILATION_CONDITIONS="]
    if promotion:
        # Merged into the generated Info.plist: display links may run at 120 Hz.
        # Only the app target reads BENCH_INFOPLIST (see the project's build settings).
        command += ["BENCH_INFOPLIST=TranscriptBench/Info-ProMotion.plist"]
    if physical:
        command += ["-destination", f"platform=iOS,id={device}", "-derivedDataPath", "../.build/bench-device",
                    "-allowProvisioningUpdates", f"DEVELOPMENT_TEAM={team}", "CODE_SIGN_STYLE=Automatic"]
    else:
        command += ["-destination", f"platform=iOS Simulator,id={device}", "-derivedDataPath", "../.build/bench"]
    subprocess.run(command, cwd=HERE, check=True)


def install(device, physical):
    if physical:
        subprocess.run(["xcrun", "devicectl", "device", "install", "app", "--device", device, DEVICE_APP],
                       check=True, capture_output=True)
    else:
        subprocess.run(["xcrun", "simctl", "install", device, APP], check=True)


def run_once(device, renderer, scenario, physical):
    name, chars, rate, history, interval, corpus = unpack(scenario)
    arguments = ["-renderer", renderer, "-scenario", name, "-chars", str(chars), "-rate", str(rate),
                 "-history", str(history), "-interval", str(interval)]
    if name.endswith("scroll"):
        arguments += ["-mode", "scroll"]
    if corpus != "answer":
        arguments += ["-corpus", corpus]
    arguments += EXTRA_ARGUMENTS
    if physical:
        command = ["xcrun", "devicectl", "device", "process", "launch", "--device", device, "--console",
                   "--terminate-existing", BUNDLE, "--"] + arguments
    else:
        command = ["xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", device, BUNDLE] + arguments
    timeout = chars / rate + 120
    try:
        output = subprocess.run(command, capture_output=True, text=True, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        if not physical:
            subprocess.run(["xcrun", "simctl", "terminate", device, BUNDLE], capture_output=True)
        return None
    for line in output.splitlines():
        if "BENCH_RESULT " in line:
            return json.loads(line.split("BENCH_RESULT ", 1)[1])
    return None


def median(runs, path):
    values = []
    for run in runs:
        value = run
        for key in path:
            value = value.get(key) if isinstance(value, dict) else None
            if value is None:
                break
        if value is not None:
            values.append(value)
    return statistics.median(values) if values else None


def fmt(value, digits=1):
    return "–" if value is None else f"{value:.{digits}f}"


def summarise(results, repeats):
    lines = []
    for scenario in SCENARIOS:
        name, chars, rate, history, interval, corpus = unpack(scenario)
        if not any(r["scenario"] == name for r in results):
            continue
        text = "" if corpus == "answer" else f", {corpus} text"
        if name.endswith("scroll"):
            lines.append(f"### {name}: scrolling through {history} earlier messages at 3000 points/s for 10 s{text}\n")
        else:
            lines.append(f"### {name}: {chars} characters at {rate}/s, {history} earlier messages, an update every {interval} ms{text}\n")
        lines.append("| Renderer | Runs | Dropped frames | Hitch ms/s | Worst frame ms | Main-thread CPU s | Process CPU s | Memory after MB | In use after MB | Memory peak MB | Page dropped frames |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|---|")
        present = [r for r in RENDERERS if any(x["renderer"] == r for x in results)]
        for renderer in present:
            runs = [r for r in results if r["renderer"] == renderer and r["scenario"] == name and r.get("ok")]
            failed = sum(1 for r in results if r["renderer"] == renderer and r["scenario"] == name and not r.get("ok"))
            runs_text = f"{len(runs)}/{len(runs) + failed}"
            lines.append("| " + " | ".join([
                renderer, runs_text,
                fmt(median(runs, ["frames", "droppedFrames"]), 0),
                fmt(median(runs, ["frames", "hitchMsPerSecond"])),
                fmt(median(runs, ["frames", "worstFrameMs"])),
                fmt(median(runs, ["mainThreadCPUSeconds"]), 2),
                fmt(median(runs, ["processCPUSeconds"]), 2),
                fmt(median(runs, ["memoryAfterMB"]), 0),
                fmt(median(runs, ["memoryAfterReliefMB"]), 0),
                fmt(median(runs, ["memoryPeakMB"]), 0),
                fmt(median(runs, ["pageFrames", "droppedFrames"]), 0),
            ]) + " |")
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--physical", action="store_true", help="the device is a real iPhone, not a simulator")
    parser.add_argument("--team", help="development team ID, for building to a real device")
    parser.add_argument("--out", default="results", help="output folder inside Benchmark/")
    parser.add_argument("--renderers", help="comma-separated subset to run; their old results are replaced, others kept")
    parser.add_argument("--scenarios", help="comma-separated subset of scenarios to run, combined with --renderers")
    parser.add_argument("--summarise-only", action="store_true", help="rebuild the tables from results.json")
    parser.add_argument("--app-args", default="", help="extra launch arguments for the app, space-separated")
    parser.add_argument("--promotion", action="store_true", help="with --build: let the app run at 120 Hz on ProMotion phones")
    args = parser.parse_args()
    EXTRA_ARGUMENTS.extend(args.app_args.split())

    out = os.path.join(HERE, args.out)
    if args.summarise_only:
        with open(os.path.join(out, "results.json")) as handle:
            table = summarise(json.load(handle), args.repeats)
        with open(os.path.join(out, "tables.md"), "w") as handle:
            handle.write(table + "\n")
        print(table)
        return

    if not args.device:
        parser.error("--device is required unless --summarise-only is given")
    if args.build:
        build(args.device, args.physical, args.team, args.promotion)
    install(args.device, args.physical)

    selected = args.renderers.split(",") if args.renderers else RENDERERS
    scenarios = [s for s in SCENARIOS if not args.scenarios or s[0] in args.scenarios.split(",")]
    names = [s[0] for s in scenarios]
    results = []
    existing = os.path.join(out, "results.json")
    if (args.renderers or args.scenarios) and os.path.exists(existing):
        with open(existing) as handle:
            results = [r for r in json.load(handle) if not (r["renderer"] in selected and r["scenario"] in names)]
    for scenario in scenarios:
        for repeat in range(args.repeats):
            for renderer in selected:
                result = run_once(args.device, renderer, scenario, args.physical)
                if result is None:
                    result = {"renderer": renderer, "scenario": scenario[0], "ok": False}
                else:
                    result["ok"] = True
                result["repeat"] = repeat
                results.append(result)
                status = "ok" if result["ok"] else "NO RESULT"
                print(f"{scenario[0]:8} {renderer:17} run {repeat + 1}: {status}", flush=True)

    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "results.json"), "w") as handle:
        json.dump(results, handle, indent=1)
    table = summarise(results, args.repeats)
    with open(os.path.join(out, "tables.md"), "w") as handle:
        handle.write(table + "\n")
    print("\n" + table)


if __name__ == "__main__":
    sys.exit(main())
