# Redacter action

GitHub Action that runs [redacter](https://github.com/abdolence/redacter-rs) in a workflow. It detects secrets and
personal data (PII) in the files of a repository and fails the build when it finds any, redacts files before they are
published or uploaded as artefacts, and reports both as SARIF, the format GitHub code scanning reads, so findings appear
on the Security tab and on pull requests.

## Usage

A single action covers both operations, selected with the `command` input.

Scan gate on pull requests, with the findings uploaded to code scanning:

```yaml
name: Scan for secrets
on: pull_request

jobs:
  scan:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@v7
      - id: redacter
        uses: abdolence/redacter-action@v1
        with:
          command: scan
          categories: secrets
      - uses: github/codeql-action/upload-sarif@v4
        if: always() && steps.redacter.outputs.sarif-file != ''
        with:
          sarif_file: ${{ steps.redacter.outputs.sarif-file }}
          category: redacter-scan
```

- `categories: secrets` limits the scan to credentials. Source code holds many strings that match the personal data
  rules, such as IPv6 addresses in Rust paths and Unix timestamps in the shape of a Swedish personal number;
- the step fails when redacter finds something, and the upload still runs: the action sets `sarif-file` before it
  fails;
- the scan leaves `.git` directories out. A `.redacterignore` file at the root of the repository keeps the mock keys
  of test fixtures out of the scan;
- `redacter:allow` on a line, or `redacter:allow-begin` and `redacter:allow-end` around several lines, keep single
  findings out of the scan. A marker that does not pair up is a warning in the notifications of the SARIF report, and
  hides nothing. See
  [Ignoring files and findings](https://github.com/abdolence/redacter-rs#ignoring-files-and-findings).

Redaction of files before they are uploaded:

```yaml
jobs:
  redact:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: abdolence/redacter-action@v1
        with:
          command: cp
          path: logs/
          destination: redacted-logs/
      - uses: actions/upload-artifact@v7
        with:
          name: redacted-logs
          path: redacted-logs/
```

A file that no redacter reads is left out of the copy. A file that fails is not copied either, and the step fails.

## Inputs

| Input | Default | Description |
|---|---|---|
| `command` | Required | `scan` reports the secrets and personal data it finds, `cp` copies files with them redacted |
| `path` | `.` | File or directory to scan or copy, relative to the workspace |
| `destination` | | Where `cp` writes the redacted copy, ending with `/` for a directory. `cp` only |
| `redacters` | `local-rules` | Redacters to run, separated by commas or new lines, see [What runs where](#what-runs-where) |
| `categories` | Every category | Data categories to look for, separated by commas or new lines, such as `secrets`, or only exclusions such as `!other`, see [Limiting to data categories](https://github.com/abdolence/redacter-rs#limiting-to-data-categories) |
| `fail-on` | `findings` | What makes `scan` fail: `findings`, `unconfirmed` or `never`. `scan` only |
| `addons` | `auto` | Addons to install and cache: `auto`, `none`, or a list such as `ocr,pdf` |
| `cache` | `true` | `true` caches the addons between runs, `false` downloads them on every run, see [What runs where](#what-runs-where) |
| `version` | `0.22.2` | The redacter release to install, 0.22.0 or later |
| `args` | | Further redacter arguments, one per line, such as `--local-rules=secrets,url` |

Addons are the files redacter needs and does not bundle: the OCR models (`ocr`), the Pdfium library that renders PDF
pages (`pdf`), and the models of `local-ner`, `local-gliner` and `local-credential-ml`. `auto` installs `ocr`, `pdf`
and the models of the redacters in `redacters`. With `none` the action installs nothing, and redacter looks for addons
in its default directory or in `REDACTER_ADDONS_DIR`.

The default `version` is the release the action was tested with, so a workflow that pins a release of the action
installs the same redacter on every run. The action holds the SHA-256 digests of its archives and refuses an archive
that differs, so installing the default version makes no request to the GitHub API and needs no token.

The action passes `--unsupported-as-text`, so `.env` files, keys and source code are read as text, and writes the
SARIF report with `--report-file` and `--report-format`. `args` cannot set these options again, as redacter rejects a
repeated option. `args` does not accept `--show-values` either: it writes the values found to the log of the run, which
everyone with read access to the repository can see.

## Outputs

| Output | Description |
|---|---|
| `sarif-file` | Path of the SARIF report in the temporary directory of the runner, for `github/codeql-action/upload-sarif`. Set whenever redacter wrote a report, also when the step fails on its exit code |
| `findings` | Number of findings in the SARIF report: what `scan` found, or what `cp` redacted. Unconfirmed files are not counted. A SARIF report keeps at most 5000 results |
| `exit-code` | Exit code of redacter: `0`, `2` when `scan` reported findings or, with `fail-on: unconfirmed`, unconfirmed files, or `1` on an error |
| `cache-hit` | `true` when the addons were restored from the cache and `false` when the cache had none. Empty when `cache` is `false` or there are no addons |

The step fails when the exit code is not `0`. See [Exit codes](https://github.com/abdolence/redacter-rs#exit-codes)
for what each one means for `scan`. `cp` exits with `1` when a file fails.

An unconfirmed file is one where a model named values that redacter could not locate in the file. It is a warning in the
report, and `fail-on: unconfirmed` fails the step for it. Such a step has `exit-code` `2` and `findings` `0`, so a later
step that gates on `findings` also checks `exit-code`.

## What runs where

- the action downloads the redacter release archive for the runner from
  [the releases of redacter-rs](https://github.com/abdolence/redacter-rs/releases), and checks its SHA-256 digest
  before it extracts it. For the default `version` the digests are in the action. For another `version` the action
  reads the digest GitHub records for the file in the release, with the token of the workflow on github.com, since the
  API allows anonymous requests only 60 an hour for each IP address. That digest detects a corrupted download, and a
  release asset that was replaced has a new digest;
- `redacter addons install` downloads the addons from the same releases and checks every file against a digest pinned
  in redacter. `actions/cache` keeps them under a key of the runner, the redacter version and the addon list, and later
  runs restore them instead. The cache is saved before redacter runs, so a scan that fails on findings still fills it.
  A repository has 10 GB of Actions cache, so `cache: false` keeps the addons out of it, at the cost of downloading
  them on every run;
- the local redacters run on the runner, and no data leaves it. The default, `local-rules`, needs no credentials and
  no model. `local-credential-ml` is opt-in, as on source code it flags test vectors and public keys; add it with
  `redacters: local-rules,local-credential-ml`, and it downloads a model of about 130 MB on the first run.
  `local-gliner` downloads a model of about 1.17 GB;
- the cloud redacters (GCP DLP, AWS Comprehend, AWS Bedrock and Guardrails, Vertex AI, Gemini, OpenAI) send the content
  of the files to their provider, and Presidio sends it to the server you run. They take credentials as the command
  line tool does, for example from `google-github-actions/auth` or `aws-actions/configure-aws-credentials`, and their
  options through `args`;
- the log and the SARIF report show values masked, such as `A******************E` for an AWS access key. The report
  stays on the runner until a step such as `github/codeql-action/upload-sarif` uploads it.

The action runs on Linux X64 and ARM64, macOS X64 and ARM64, and Windows X64 runners, such as `ubuntu-latest`,
`ubuntu-24.04-arm`, `macos-latest`, `macos-15-intel` and `windows-latest`, and fails on other runners. It reads the
release and the SARIF report with `jq`, which GitHub-hosted runners have.

## More about redacter

- [redacter-rs](https://github.com/abdolence/redacter-rs): the command line tool;
- [Scan command](https://github.com/abdolence/redacter-rs#scan-command): reports, scores and exit codes;
- [DLP comparison](https://github.com/abdolence/redacter-rs/blob/master/docs/dlp-comparison.md): measured quality and
  speed of every redacter.

## Licence

Apache License 2.0, see [LICENSE](LICENSE).
