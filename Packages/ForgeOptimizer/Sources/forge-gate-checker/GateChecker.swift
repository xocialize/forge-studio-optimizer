//
// forge-gate-checker
//
// CLI per Forge-BenchmarkSchema-v1.0.md §6. Reads a current report and
// (optionally) a baseline report; re-evaluates the current report's
// gates and diffs against the baseline's `gates.results`. Honors the
// schema §6 `--fail-on regression` semantic — newly failing gates
// that weren't passing in the baseline are warnings, not failures.
//
// Usage:
//   forge-gate-checker --report <current.json> [--baseline <baseline.json>]
//                      [--fail-on regression|any]      (default: regression)
//
// Exit codes:
//   0 = all gates passed, or no regressions vs baseline
//   1 = at least one gate regressed from passed:true → passed:false
//   2 = system error (file not found, parse error, missing flag)
//
// Per Forge 2026 Q2 refresh plan §A.2.
//

import ForgeOptimizer
import Foundation

@main
struct ForgeGateChecker {
    static func main() {
        let argv = CommandLine.arguments
        do {
            let opts = try parseArgs(argv)
            try run(opts)
        } catch let err as CheckerError {
            FileHandle.standardError.write(Data("forge-gate-checker: \(err.description)\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("forge-gate-checker: unexpected error: \(error)\n".utf8))
            exit(2)
        }
    }
}

struct CheckerOptions {
    var report: URL
    var baseline: URL?
    var failOn: FailMode
}

enum FailMode: String {
    case regression
    case any
}

enum CheckerError: Error, CustomStringConvertible {
    case missingRequired(String)
    case unknownFlag(String)
    case fileNotFound(URL)
    case parseFailed(URL, String)

    var description: String {
        switch self {
        case .missingRequired(let f): return "missing required flag \(f)"
        case .unknownFlag(let f):     return "unknown flag '\(f)'"
        case .fileNotFound(let url):  return "file not found: \(url.path)"
        case .parseFailed(let url, let d):
            return "could not parse \(url.lastPathComponent) as a Forge benchmark report: \(d)"
        }
    }
}

func parseArgs(_ argv: [String]) throws -> CheckerOptions {
    var report: URL?
    var baseline: URL?
    var failOn: FailMode = .regression

    var i = 1
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--help", "-h":
            printUsage()
            exit(0)
        case "--report":
            guard i + 1 < argv.count else { throw CheckerError.missingRequired("--report") }
            report = URL(fileURLWithPath: argv[i + 1])
            i += 2
        case "--baseline":
            guard i + 1 < argv.count else { throw CheckerError.missingRequired("--baseline") }
            baseline = URL(fileURLWithPath: argv[i + 1])
            i += 2
        case "--fail-on":
            guard i + 1 < argv.count else { throw CheckerError.missingRequired("--fail-on") }
            guard let mode = FailMode(rawValue: argv[i + 1]) else {
                throw CheckerError.unknownFlag("--fail-on value '\(argv[i + 1])'")
            }
            failOn = mode
            i += 2
        default:
            throw CheckerError.unknownFlag(arg)
        }
    }
    guard let r = report else { throw CheckerError.missingRequired("--report") }
    return CheckerOptions(report: r, baseline: baseline, failOn: failOn)
}

func printUsage() {
    let usage = """
    forge-gate-checker — diff Forge benchmark gate results against a baseline.

    Usage:
      forge-gate-checker --report <current.json>
                         [--baseline <baseline.json>]
                         [--fail-on regression|any]   # default: regression

    Exit codes:
      0  no regressions (or all gates pass when no baseline)
      1  at least one gate regressed
      2  system error (missing args, file not found, parse error)

    Behavior per Forge-BenchmarkSchema-v1.0.md §6:
      --fail-on regression — fail only on baseline-passed→current-failed transitions
      --fail-on any        — fail on any failing gate (ignores baseline)
    """
    print(usage)
}

func run(_ opts: CheckerOptions) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: opts.report.path) else {
        throw CheckerError.fileNotFound(opts.report)
    }
    let current = try decodeReport(at: opts.report)

    // Re-evaluate the current report's gates from scratch — this is a
    // sanity check: if the report's pipeline_results don't agree with
    // gates.results, the evaluator wins. The current-file's stored
    // gates are still printed for diff transparency.
    let evaluator = GateEvaluator()
    let recomputed = evaluator.evaluate(report: current)

    // Print the current results table.
    print("forge-gate-checker: report \(opts.report.lastPathComponent)")
    print("forge-gate-checker:   run_label = \(current.runLabel)")
    print("forge-gate-checker:   git.sha   = \(current.git.sha)")
    print("forge-gate-checker:   hardware  = \(current.hardware.chip)")
    print("")
    print("Gate                                         Status   Actual          Target")
    print("--------------------------------------------- ------- --------------- ---------------")
    for r in recomputed.results {
        let status = r.passed ? "PASS" : "FAIL"
        let actual = String(format: "%.4f", r.actual)
        let target = String(format: "%.4f", r.target)
        let name = r.gateID.padding(toLength: 45, withPad: " ", startingAt: 0)
        let actualPad = actual.padding(toLength: 15, withPad: " ", startingAt: 0)
        print("\(name) \(status.padding(toLength: 7, withPad: " ", startingAt: 0)) \(actualPad) \(target)")
    }
    print("")

    // Diff against baseline, if supplied.
    var regressions: [String] = []
    var newFailures: [String] = []
    var newPasses: [String] = []
    if let baselineURL = opts.baseline {
        guard fm.fileExists(atPath: baselineURL.path) else {
            throw CheckerError.fileNotFound(baselineURL)
        }
        let baseline = try decodeReport(at: baselineURL)
        let baselineByID = Dictionary(
            uniqueKeysWithValues: baseline.gates.results.map { ($0.gateID, $0) }
        )
        for current in recomputed.results {
            if let prev = baselineByID[current.gateID] {
                if prev.passed && !current.passed {
                    regressions.append(current.gateID)
                } else if !prev.passed && current.passed {
                    newPasses.append(current.gateID)
                }
            } else if !current.passed {
                // Brand-new gate that's failing — warning, not failure.
                newFailures.append(current.gateID)
            }
        }
        print("forge-gate-checker: diff vs baseline \(baselineURL.lastPathComponent)")
        if regressions.isEmpty && newFailures.isEmpty && newPasses.isEmpty {
            print("forge-gate-checker:   no changes")
        } else {
            for id in regressions {
                print("forge-gate-checker:   REGRESSION (was passing, now failing): \(id)")
            }
            for id in newPasses {
                print("forge-gate-checker:   improvement (was failing, now passing): \(id)")
            }
            for id in newFailures {
                print("forge-gate-checker:   warning (new gate, failing): \(id)")
            }
        }
        print("")
    }

    // Decide exit code per --fail-on mode.
    let failing = recomputed.results.filter { !$0.passed }
    switch opts.failOn {
    case .regression:
        if !regressions.isEmpty {
            print("forge-gate-checker: FAIL — \(regressions.count) regression(s)")
            exit(1)
        }
        print("forge-gate-checker: OK — \(failing.count) gate(s) failing, none regressed from baseline")
        exit(0)
    case .any:
        if !failing.isEmpty {
            print("forge-gate-checker: FAIL — \(failing.count) gate(s) failing (--fail-on any)")
            exit(1)
        }
        print("forge-gate-checker: OK — all \(recomputed.results.count) gates passing")
        exit(0)
    }
}

func decodeReport(at url: URL) throws -> BenchmarkReport {
    do {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BenchmarkReport.self, from: data)
    } catch {
        throw CheckerError.parseFailed(url, "\(error)")
    }
}
