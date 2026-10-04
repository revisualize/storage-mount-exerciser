# storage-mount-exerciser

[![ci](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/ci.yml/badge.svg)](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/ci.yml)
[![test](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/test.yml/badge.svg)](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/test.yml)
[![shellcheck](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/shellcheck.yml)
[![bash-compat](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/bash-compat.yml/badge.svg)](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/bash-compat.yml)
[![markdown-lint](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/markdown-lint.yml/badge.svg)](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/markdown-lint.yml)
[![links](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/links.yml/badge.svg)](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/links.yml)
[![content-policy](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/content-policy.yml/badge.svg)](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/content-policy.yml)
[![license: all rights reserved](https://img.shields.io/badge/license-all%20rights%20reserved-lightgrey)](LICENSE)

A data-path canary for NFS exports and SMB shares. It mounts, writes, reads back, verifies byte for byte, deletes, and unmounts, timing every phase in milliseconds and appending the result to a CSV history, so "the share feels slow" becomes a question with a baseline instead of a vibe.

This is a canary, not a benchmark. If you need controlled I/O characterization with queue depths and block size sweeps, that tool exists and it is called `fio`.

## Usage

```sh
# One time: bless the scratch area, deliberately, by hand.
mount -t nfs storage01:/export/data /mnt/check
mkdir -p /mnt/check/monitoring/exerciser_scratch
touch /mnt/check/monitoring/exerciser_scratch/.mount_exerciser_scratch_area
umount /mnt/check

# Then, from cron:
storage_mount_exerciser.sh
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Every phase passed |
| 1 | A phase failed (mount, write, read, delete, unmount) |
| 2 | Configuration, dependency, lock, or safety contract error |
| 3 | **Integrity mismatch**: bytes read back differ from bytes written |

Exit 3 is deliberately distinct. A latency problem and a corruption problem are not the same finding, and the alerting that routes them should not be the same either.

## The write safety contract

Any tool that writes to production storage on a schedule needs a mechanism, not a convention, standing between it and the wrong directory. The exerciser writes only inside a directory containing a marker file named `.mount_exerciser_scratch_area`, placed there once, by a human, on purpose. No marker, no writes, hard exit. A typo in the scratch path fails closed instead of scattering test files through a production tree.

## The CSV history

```text
timestamp,protocol,outcome,failed_phase,mount_ms,write_ms,read_ms,verify_ms,delete_ms,unmount_ms
```

Failed runs are recorded too. A history that contains only successes cannot answer "how often does this break," which is half the question the CSV exists to answer. Phases that were never reached are empty fields, never zero, because zero is a latency claim and empty is not.

## Configuration

| Variable | Default |
|----------|---------|
| `EXERCISER_PROTOCOL` | `nfs` |
| `EXERCISER_NFS_SERVER` | `storage01.example.net` |
| `EXERCISER_NFS_EXPORT` | `/export/data` |
| `EXERCISER_SMB_SERVER` | `storage01.example.net` |
| `EXERCISER_SMB_SHARE` | `data` |
| `EXERCISER_SMB_CREDENTIALS` | `/etc/storage_mount_exerciser/smb_credentials` |
| `EXERCISER_SCRATCH_RELATIVE` | `monitoring/exerciser_scratch` |
| `EXERCISER_PAYLOAD_KB` | `1024` |
| `EXERCISER_WARN_MS` | `2000` |
| `EXERCISER_HISTORY_FILE` | `/var/lib/storage_mount_exerciser/history.csv` |
| `EXERCISER_PHASE_TIMEOUT` | `30` |

## Design notes

**Timing includes a flush, or the write number is fiction.** A plain write into a mounted filesystem can land in the client page cache and return in microseconds, telling you nothing about the storage. The write phase uses `dd conv=fsync`, so the measured time includes the round trip that matters. This is durable-write latency, which is the honest number and also the slower one, so do not compare it against cached-write figures from other tools.

**The payload is generated once, locally, before the clock starts.** Reading `/dev/urandom` during a timed phase would bill entropy generation to the storage.

**Verification is `cmp`, not a checksum comparison.** It proves the bytes that came back are the bytes that went in, byte for byte, and stops at the first difference.

**Soft mount with bounded timeouts, because a hung canary is worse than a dead one.** Production data wants hard mounts. A monitoring tool wants the opposite: it must always terminate, report, and release its mount point.

**Every exit path records a row.** The caller owns the exit, phases return rather than exiting, and the history is a complete record of what was attempted rather than a highlight reel.

## Known limitations

- The mount and unmount phases require real storage and are not covered by the test suite. Everything from the safety contract through verification is exercised against a local directory. Shake the mount path down in a lab before trusting it in production.
- One small file through one code path. It detects that the end-to-end client experience changed. It cannot isolate which component changed.
- The exerciser records; it does not judge. Deciding whether a number is bad against trailing history is a separate concern.

## Requirements

Bash 4.2 or newer, GNU coreutils (`date +%s%N`), util-linux (`flock`, `mountpoint`), and `mount.nfs` or `mount.cifs`.

## Tests

```sh
bats test/
```

## Continuous integration

Each badge above is its own GitHub Actions workflow in `.github/workflows/`. Every workflow runs on each push and pull request, can be re-run by hand from the Actions tab, and links to its run history.

| Workflow | A green badge means |
|---|---|
| [`ci`](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/ci.yml) | `bash test/run_all_tests.sh` passed on Python 3.9 and 3.12 and reported a non-zero count of executed tests, and shellcheck found nothing at style severity. |
| [`test`](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/test.yml) | `bash test/run_all_tests.sh` passed on Python 3.9 and 3.12. The run fails if any suite fails or if zero tests executed, and the job summary lists each suite with its test count. |
| [`shellcheck`](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/shellcheck.yml) | Every shell script outside `test/fixtures/` parses with `bash -n` and has no shellcheck findings at style severity. |
| [`bash-compat`](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/bash-compat.yml) | The test suite passed under every Bash release from the floor stated in Requirements through 5.3, each built from its release source. |
| [`markdown-lint`](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/markdown-lint.yml) | Every Markdown file passes markdownlint. |
| [`links`](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/links.yml) | Every link in every Markdown file resolved on the latest run. It also runs weekly, because a link can break with no commit here. |
| [`content-policy`](https://github.com/revisualize/storage-mount-exerciser/actions/workflows/content-policy.yml) | Every tracked file meets the publishing rules: UTF-8, LF line endings, no em dashes, scripts documented as `bash name.sh`, and vendor-neutral wording. |

A badge reports the latest run of those checks. What the tool needs on your own host is listed under Requirements.

## License

See [LICENSE](LICENSE). This code is published for viewing as a sample of the author's work. All rights reserved.
