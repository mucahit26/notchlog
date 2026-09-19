import Foundation
import NotchLogKit

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "selftest":
    print("notchlog \(NotchLog.version) — self test")
    let report = SelfTest.run()
    print("")
    if report.ok {
        print("PASS — \(report.passed) checks")
        exit(0)
    } else {
        print("FAIL — \(report.passed) passed, \(report.failures.count) failed:")
        for f in report.failures { print("  ✗ \(f)") }
        exit(1)
    }
case "version", "--version", "-v":
    print(NotchLog.version)
case "help", "--help", "-h":
    print("""
    notchlog \(NotchLog.version)

      notchlog             run the monitor (normally started by launchd)
      notchlog selftest    verify the parsers against your own system
      notchlog version
    """)
default:
    print("notchlog \(NotchLog.version) — UI not wired up yet")
}
