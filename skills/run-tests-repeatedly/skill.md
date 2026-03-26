---
name: run-tests-repeatedly
description: Run tests repeatedly until they fail or pass a certain number of times
---

# Run Tests Repeatedly

Run `just test` until an error is reported or until the tests pass a maximum number of times.
If not specified, the maximum number should default to 100. If the testing reveals an error, 
report the error (and as much useful context as you can, including the iteration number it 
happened on) back to the user or invoking agent. If you reach the maximum number of runs, report
back that no errors were encountered after N runs to the user or invoking agent.

If the user or invoking agent requests that you run only specific tests,
run `just test <SPM TEST ARGS>`, where `<SPM TEST ARGS>` are arguments to pass to `swift test`,
such as test filter arguments.