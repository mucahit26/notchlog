# Parser fixtures

Real captured output from `ps` and `nettop` on macOS 27 (Apple Silicon), kept as
documentation of the exact formats the parsers must handle:

| file | command |
|---|---|
| `ps_sample.txt` | `/bin/ps -Aeo pid,ppid,rss,time,comm -r` |
| `nettop_conn.txt` | `/usr/bin/nettop -x -n -l 1 -J bytes_in,bytes_out -t external` |
| `nettop_proc.txt` | `/usr/bin/nettop -P -x -n -l 1 -J bytes_in,bytes_out -t external` |

Notable cases these capture: executable paths containing spaces, process names
truncated to 15 characters, names containing dots (`com.apple.Drive.751`), and a
cumulative CPU `TIME` whose minutes field exceeds 60 (`256:48.19`).

Run `notchlog selftest` to exercise the parsers against both these edge cases and
live output from your own machine.
