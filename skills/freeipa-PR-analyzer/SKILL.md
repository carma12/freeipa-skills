---
name: freeipa-PR-analyzer
description: Use when analyzing failed FreeIPA CI test logs to generate failure hypothesis with citations and infrastructure context
license: MIT
metadata:
  author: "Rafael Guterres Jeffman <rjeffman@redhat.com>"
  version: "1.0"
compatibility: Requires curl, jq, sort and sed
allowed-tools: Read Bash(${CLAUDE_PLUGIN_ROOT}/scripts/download-pr-artifacts.sh *) Bash(mkdir -p *) Bash(curl*github.com/freeipa/freeipa*) Bash(ls *)
---

# FreeIPA Azure Analyzer

## Overview

Skill for systematically analyzing Azure DevOps CI logs from failed FreeIPA tests. Generates structured failure hypotheses with log citations, infrastructure context, and causal reasoning.

**Core principle:** Failed test analysis is detective work—classify the failure type (code regression vs. infrastructure), identify supporting evidence, cite exact log locations, and rank hypotheses by likelihood given the available data.

## When to Use

- Analyzing failed test logs from `./artifacts/pr-<PR_ID>/` (artifacts are downloaded automatically)
- Need to determine if a PR failure is code-related or infrastructure-related
- Must document findings in `./results/pr-<PR_ID>/analysis.md` with evidence citations
- Working with FreeIPA CI logs (complex nested container execution, pytest output in Azure Pipelines format)

**Symptoms that signal this skill:**
- Truncated or missing pytest output in log files
- Uncertain whether failure is caused by PR changes or CI flakiness
- Need to parse interleaved Azure agent metadata, container exec output, and test results
- Multiple test suites (base, xmlrpc, etc.) running in sequence with separate exit codes

## Failure Classification Framework

Before analyzing evidence, classify the failure into one of these categories. This shapes what evidence matters:

| Category | Signals | Evidence Focus |
|----------|---------|-----------------|
| **Test Code Failure** | Pytest `FAILED` or `ERRORS` in output; specific assertion failures | Exact test name, traceback, assertion, whether failure is deterministic |
| **Product Code Regression** | Tests that passed before now fail; failure affects multiple suites; no infrastructure signals | PR diff vs. failed test scope, whether new code touches test prerequisites |
| **Infrastructure/Flaky** | No pytest output or truncated log; timeout signals (job duration near 60min limit); OOM/memory signals; DNS/time-sync errors | Memory usage, job timeline, container resource limits, system journal errors |
| **CI Configuration** | Test collection errors; environment variable issues; fixture setup errors; container provisioning failures | Log timestamp gaps (missing output during test run), container error messages, chronyc/DNS failures |

**Key insight:** A failure with no pytest `FAILED` lines is NOT a test code failure—focus on infrastructure and timeline instead.

## Log Parsing Mechanics

### Step 1: Understand the Log Structure

FreeIPA CI logs are hierarchical:
```
[Azure Pipelines metadata + job start]
[Host provisioning: OS, kernel, podman]
[Container setup: podman-compose, podman version check]
[Test execution: base suite then xmlrpc suite in sequence]
  - Each suite: container provisioning → server install → pytest → server cleanup
  - Each suite: separate exit code (result: 0 or result: 1)
  - Pytest output nested inside podman exec: prefixed with "1\t[timestamp]"
[Post-test diagnostics: memory, journal, disk]
[Azure artifact upload]
```

**Critical:** The log file may NOT contain the full pytest output. Look for gaps:
- Time discontinuity (e.g., timestamp jumps 15 minutes with no intervening lines)
- Suite ran (duration reported) but no pytest summary
- `result: 1` but no `FAILED` or `= FAILURES =` section

If gaps exist, the full pytest output may be in a separate artifact or was lost—note this as "truncated log, hypothesis confidence is low."

### Step 2: Extract Test Results Summary

Find the results lines near end of log. Pattern: `tests: <suite>, result: <CODE>, time: <DURATION>`

```
tests: base, result: 0, time: 27:46.98
tests: xmlrpc, result: 1, time: 42:47.45
```

**Interpret codes:**
- `result: 0` = suite passed (may still have skipped tests)
- `result: 1` = suite failed (exit code 1; check pytest output for reason)
- Exit code ≠ pytest failure count (e.g., pytest can pass 100 tests but exit 1 due to collection error)

Create a results table for the report:
```markdown
| Suite   | Result | Duration | Interpretation |
|---------|--------|----------|-----------------|
| base    | 0      | 27:46    | Passed         |
| xmlrpc  | 1      | 42:47    | Failed (see evidence) |
```

### Step 3: Extract Pytest Output (If Present)

Search for pytest markers in order of likelihood:
1. `=== short test summary info ===` — **most reliable**, always present if pytest ran
2. Individual `PASSED`, `FAILED`, `SKIPPED` lines with test names
3. `= FAILURES =` section with tracebacks
4. `collected X items` — how many tests were collected

**Strip ANSI codes** when quoting:
- `[32m` (green), `[31m` (red), `[33m` (yellow), `[0m` (reset) are color sequences
- Remove these for clean markdown quotes

**If pytest output is absent:** Note "pytest output not found in log (possible truncation or separate artifact)". Shift focus to infrastructure analysis.

### Step 4: Extract Infrastructure Signals

Scan for patterns specific to FreeIPA CI failures:

**Memory/Resource:**
- `memory.failcnt: <N>` in `free -m` or cgroup output (N > 0 = OOM events)
- Container memory limits: `--memory=1800m` for server/replica, `--memory=512m` for client
- Job timeout: `SYSTEM_JOBTIMEOUT=60` means 60-minute hard limit
- Check if total suite duration + overhead approaches limit

**Time/Sync:**
- `chronyc waitsync failed` — time sync issue (can cause cert validation failures)
- `systemctl status chrony` showing inactive/failed
- NTP errors in Azure agent logs

**Container/Storage:**
- `Error: no container with name or ID` — podman provisioning failure
- Disk usage near 100% in container (`df -h`)
- `Failed to connect to systemd bus` — container init issues

**Network/DNS:**
- DNS lookup failures: `Name or service not known`
- Connection timeouts to replica or client
- Socket errors in pytest output

**Job Timeline:**
- Long gaps between timestamps (missing output = test ran in unlogged container)
- Base suite duration + xmlrpc suite duration ≈ total job time (if close to 60min, timeout likely)

### Step 5: Correlate Evidence to Hypothesis

Once you have results, pytest output (or note its absence), and infrastructure signals, form a hypothesis:

**Causal chain structure:**
1. **Observed failure:** What specific test or suite returned a non-zero exit code?
2. **Direct cause:** Why did it fail? (specific assertion, infrastructure event, timeout, etc.)
3. **Root cause:** What infrastructure or code condition led to the direct cause?
4. **Likelihood:** How confident are you, given available evidence?

Example causal chain:
- **Observed:** xmlrpc suite `result: 1`, no pytest output in log
- **Direct cause:** Likely timeout or test runner killed before producing output
- **Root cause:** Job duration (base 27:46 + xmlrpc 42:47 + overhead = ~75 min, exceeds 60-min SYSTEM_JOBTIMEOUT)
- **Likelihood:** Medium-High (duration math is solid, but xmlrpc output gap prevents 100% certainty)

## Output Format

Save analysis to `./results/pr-<PR_ID>/<job_name>-analysis.md` with this structure:

```markdown
# FreeIPA CI Failure Analysis: PR #<PR_ID>

## Summary
- **Build ID:** <build_id>
- **Job:** <job_name>
- **Build Result:** <result>
- **Date:** <timestamp>
- **Failed Suites:** <list with result codes>

## Test Results Overview
| Suite   | Result | Duration | Interpretation |
|---------|--------|----------|-----------------|
| base    | <code> | <dur>    | <pass/fail>    |
| xmlrpc  | <code> | <dur>    | <pass/fail>    |

## Failure Hypothesis

### Primary Hypothesis: <one-line summary>
<paragraph explaining the hypothesis and causal chain>

**Confidence:** [Low | Medium | High]

### Supporting Evidence
1. **<Evidence category>** (log lines <start>-<end>)
   ```
   <verbatim log excerpt, ANSI codes stripped>
   ```
   **Significance:** <why this matters to the hypothesis>

2. **<Evidence category>** (log lines <start>-<end>)
   ```
   <verbatim log excerpt>
   ```
   **Significance:** <explanation>

### Alternative Hypotheses
- **<Alternative 1>:** <reasoning for why less likely>
- **<Alternative 2>:** <reasoning>

## Environmental Context
- **Host OS:** <os>
- **Podman Version:** <version>
- **Container Memory Limits:** Server=1800m, Replica=1800m, Client=512m
- **Job Timeout:** <SYSTEM_JOBTIMEOUT value>
- **Total Job Duration:** <time>
- **Memory/Disk Status:** <summary from host diagnostics>

## Failure Classification
**Type:** [Test Code | Product Code | Infrastructure | CI Configuration]

**Reasoning:** <explanation of why this failure falls into the chosen category>

## Known FreeIPA CI Patterns
- If OOM signals detected: container memory limits (1800m) often insufficient for concurrent server+replica
- If time-sync failures: chronyc issues cause cert validation failures in inter-host communication
- If timeout signals: base+xmlrpc runtime often approaches 60-min job limit under load
- If no pytest output: log may be truncated; xmlrpc suite output often in separate artifact

## Recommendations for PR Author
<if applicable, suggest remediation or next investigation steps>
```

## Log Citation Best Practices

**Every claim must be citable:**
- Include exact line number range from the log file
- Quote verbatim text (ANSI codes stripped)
- Show 2-3 lines of context before/after the key line
- Explain what the quote means in the context of FreeIPA CI

Example:
> **Job Timeout Signal** (lines 9672-9675):
> ```
> tests: base, result: 0, time: 27:46.98
> tests: xmlrpc, result: 1, time: 42:47.45
> + exit 1
> ##[error]Bash exited with code '1'.
> ```
> Base suite completed in 27:46. Xmlrpc suite completed in 42:47. Combined, plus container setup overhead, this exceeds the 60-minute SYSTEM_JOBTIMEOUT. The xmlrpc failure is likely a job timeout.

**Handle truncation explicitly:**
> **Note:** The xmlrpc test suite output (pytest results, PASSED/FAILED lines) is not present in this log file. The suite ran for 42:47 minutes (evidenced by the time entry above), but the container's stdout was not captured in the Azure Pipelines log. This limits confidence in root-cause analysis to infrastructure and timeline signals.

## Common FreeIPA Failure Patterns

Recognize these patterns quickly:

### 1. Memory Exhaustion (OOM)
**Signals:** `memory.failcnt > 0`, `kernel: Out of memory`, swap usage high, random test failures across suites
**Root cause:** Container memory limit (1800m) insufficient during server + replica provisioning
**Evidence to cite:** `free -m` output, cgroup memory.failcnt, journal entries

### 2. Job Timeout
**Signals:** No pytest summary for a suite; job duration base + xmlrpc ≈ 60+ minutes; xmlrpc suite no output
**Root cause:** SYSTEM_JOBTIMEOUT=60 exceeded
**Evidence to cite:** Duration lines, timestamp gaps, last log line before timeout

### 3. Time Sync Failure
**Signals:** `chronyc waitsync failed`, cert validation errors, `Bad certificate`
**Root cause:** NTP not synced → clocks skewed → cert validity checks fail
**Evidence to cite:** chronyc output, cert error tracebacks, systemctl status chrony

### 4. Container Provisioning
**Signals:** `Error: no container with name or ID`, podman-compose errors, image pull failures
**Root cause:** Podman, image registry, or compose config issue
**Evidence to cite:** podman-compose output, container error messages

### 5. Flaky/Deterministic Test Failure
**Signals:** Specific pytest `FAILED` line; traceback visible; test name clear
**Root cause:** Test code issue or race condition in product code
**Evidence to cite:** Full traceback, test name, assertion that failed

## Micro-Testing Before Hypothesis Finalization

Before committing your analysis, verify:
1. **Classification is justified:** Does your "Infrastructure" hypothesis explain why pytest output is missing? Does your "Test Code" hypothesis explain the specific assertion?
2. **Evidence is cited:** Every major claim links to specific log lines.
3. **Alternatives are considered:** Did you dismiss alternatives or just ignore them?
4. **Truncation is noted:** If log output is incomplete, does your confidence reflect that?
5. **Confidence matches evidence:** Low/Medium/High should align with data completeness and signal strength.

## Scaling to Multiple Failed Jobs

When a PR has multiple failed CI jobs (e.g., `BASE_XMLRPC`, `INTEGRATION_dns`, `ADHOC_sudo`), organize analyses as:

```
results/pr-<PR_ID>/
  BASE_XMLRPC_base_1_to_2.md           # One file per failed job
  INTEGRATION_dns_1.md
  ADHOC_sudo_1.md
  summary.md                            # Cross-job synthesis
```

**Per-job analysis:** Same format as this skill; each job's log set is independent.

**Summary file:** Create this only when 2+ job analyses exist. Contents:
- PR metadata, total jobs run, how many failed
- Table: Job | Classification | Confidence | Root Cause (one-liner)
- Cross-job correlation: Do failures share a common cause or are they independent?
- Aggregated recommendations

**File triage for efficiency:** When analyzing one job with many log files:

*Azure DevOps artifacts:*
1. **Primary:** `*_-_Run_tests.log` (test execution, pytest results)
2. **Secondary:** `*_job.log` (tail for result codes + grep for error patterns)
3. **Tertiary:** `*_-_Check_for_coredumps.log`, `*_-_Host_s_memory_statistics.log` (quick resource checks)
4. **Runner logs:** `logs-*/logs-*/base/runner_base.log`, `logs-*/logs-*/xmlrpc/runner_xmlrpc.log` (detailed test runner output per suite)
5. **Infrastructure logs:** `logs-*/logs-*/*/logs/systemd_journal.log` (system journal), `logs-*/logs-*/*/memory.stats` (container memory), `logs-*/logs-*/host_journal.log.tar.gz` (host journal)
6. **Test results:** `logs-*/logs-*/*/logs/nosetests.xml` (structured test results in XML format)
7. **Supplementary:** Everything else (environment, metadata, installed packages, docker-compose config)

*PR-CI artifacts (in `prci-*/` subdirectories):*
1. **Primary:** `runner.log` (main test runner log with pytest output)
2. **Secondary:** `metadata.json` (check `returncode` for exit status, `task_name` for test context)
3. **Config:** `ipa-test-config.yaml`, `vars.yml` (test and job configuration)
4. **Extended:** Browse the S3 URL in `job-url.txt` for per-test directories containing host journals and detailed logs

For large files (5K+ lines): Read tail first, search for patterns, full read only if needed.

Use `ls` to discover which `logs-*` and `prci-*` directories exist and what files they contain before reading.

## Integration with PR Context

After analyzing logs, cross-reference with the PR itself:
- Does the PR modify code that the failing test exercises?
- Did the PR touch infrastructure files (container config, CI scripts)?
- Are the failed tests known-flaky or newly-flaky?

This transforms log analysis into PR-specific diagnosis: "PR's changes to X caused test Y to fail because..." vs. "Infrastructure failure unrelated to PR."

**IMPORTANT: Do NOT use `gh` to access GitHub. Always use `curl` for all GitHub access.**

Use `curl` to fetch PR data and source files:
- PR details: `curl -sL https://github.com/freeipa/freeipa/pull/<PR_ID>`
- PR diff: `curl -sL https://github.com/freeipa/freeipa/pull/<PR_ID>.diff`
- PR patch: `curl -sL https://github.com/freeipa/freeipa/pull/<PR_ID>.patch`
- Source files: `curl -sL https://raw.githubusercontent.com/freeipa/freeipa/<branch>/<path>`
- PR API data: `curl -sL https://api.github.com/repos/freeipa/freeipa/pulls/<PR_ID>`
- PR changed files: `curl -sL https://api.github.com/repos/freeipa/freeipa/pulls/<PR_ID>/files`

## Prerequisites and Workflow

**Step 1: Download artifacts.** Before analyzing, check if `./artifacts/pr-<PR_ID>/` exists and is populated. If not, run the download script:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/download-pr-artifacts.sh -f <PR_ID>
```

This script:
- Queries Azure DevOps for failed jobs in the build associated with the PR
- Downloads only failed job logs (not passed jobs)
- Saves logs to `./artifacts/pr-<PR_ID>/` with names like `<JOB_NAME>_-_Run_tests.log`
- Downloads and extracts `logs-*` artifact archives into subdirectories
- Queries GitHub commit statuses for PR-CI jobs (non-Azure CI)
- Downloads PR-CI runner logs, metadata, and config to `./artifacts/pr-<PR_ID>/prci-*/`

**If the script fails:** Report the error to the user. Common causes: no builds found for the PR number, network issues, or no failed jobs in the build.

**Directory structure at analysis start:**
```
./artifacts/pr-<PR_ID>/
  # Azure DevOps artifacts
  BASE_XMLRPC_base_1_to_2_-_job.log
  BASE_XMLRPC_base_1_to_2_-_Run_tests.log
  BASE_XMLRPC_base_1_to_2_-_Check_for_coredumps.log
  ... (other log files for this job)
  logs-<JOB_NAME>-<BUILD_ID>-<N>-<N>-<N>-Linux-X64/
    logs-<JOB_NAME>-<BUILD_ID>-<N>-<N>-<N>-Linux-X64/
      host_journal.log.tar.gz
      base/
        runner_base.log
        ipa-test-config.yaml
        docker-compose.yml
        memory.stats
        installed_packages/
        logs/
          systemd_journal.log
          nosetests.xml
          ipaserver_install_logs.tar.gz
          ipaserver_uninstall_logs.tar.gz
      xmlrpc/
        runner_xmlrpc.log
        ipa-test-config.yaml
        docker-compose.yml
        memory.stats
        installed_packages/
        logs/
          systemd_journal.log
          nosetests.xml
          ipaserver_install_logs.tar.gz
          ipaserver_uninstall_logs.tar.gz
  # PR-CI artifacts (one directory per job context)
  prci-fedora-latest_temp_commit/
    job-url.txt              # URL to full PR-CI job page on S3
    runner.log               # Main test runner log (decompressed from .gz)
    metadata.json            # Job metadata (PR, task, returncode, etc.)
    ipa-test-config.yaml     # Test configuration
    vars.yml                 # Job configuration
./results/pr-<PR_ID>/
  (empty, analysis files created here)
```

### PR-CI Log Analysis

PR-CI artifacts use a different structure than Azure DevOps. Key differences:
- **`runner.log`** is the primary log file (equivalent to Azure's `Run_tests.log`)
- **`metadata.json`** contains job result info including `returncode` (non-zero = failure)
- **`job-url.txt`** contains the S3 URL where additional per-test artifacts can be browsed (per-test directories with host journals, installed packages, etc.)
- PR-CI runs on Vagrant VMs (not containers), so infrastructure signals differ from Azure

## Common Mistakes

1. **Skipping infrastructure checks:** A test failure without pytest output is almost never a test code failure.
2. **Ignoring truncation:** Confident hypothesis on incomplete data = bad diagnosis.
3. **Not citing log lines:** "There were OOM errors" is not evidence. "lines 8234-8236 show `memory.failcnt: 5`" is.
4. **Conflating correlation with causation:** A timestamp gap happened to occur during a test failure, but the gap is network latency, not test-related.
5. **Forgetting ANSI codes:** Pasting colored pytest output into markdown looks garbled. Strip escape sequences first.
6. **One hypothesis only:** Always consider 2-3 alternatives, even if you rank one as primary.
7. **Skipping the download step:** Trying to analyze before artifacts are fetched. Always verify `./artifacts/pr-<PR_ID>/` exists and is populated; if not, run `${CLAUDE_PLUGIN_ROOT}/scripts/download-pr-artifacts.sh -f <PR_ID>` first.
8. **Over-confident on truncated data:** "This must be the cause" when the log is incomplete. Low confidence is more honest and more useful.
