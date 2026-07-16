# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file Windows boot repair tool (`BootFixer.cmd`) with a Hungarian text UI. It is run inside **WinPE (Sergei Strelec boot USB)** to repair the boot configuration of an installed Windows: it detects disks via `diskpart`, finds Windows installations, then rewrites boot files (`bcdboot`) and enforces single-boot (`bcdedit`) for either UEFI/GPT or Legacy/MBR disks.

There is no build step, no tests, no dependencies. The `.cmd` file is the entire product; users copy it to a USB stick and run it as admin.

## Hard constraints

- **Pure batch only — no .NET, no compiled exe.** The tool previously was a C# exe (still in git history) and failed with `0xc0000135` in WinPE because WinPE has no .NET Framework. Everything must run with only what WinPE ships: `cmd`, `diskpart`, `bcdboot`, `bcdedit`, `bootsect`/`bootrec`, `findstr`, `ping`.
- **CRLF line endings are mandatory.** The file-writing tools emit LF-only files, and `cmd` silently mis-parses LF-only batch (symptom: chopped commands like `'et' is not recognized`, or labels not found). After any edit, ensure the file is CRLF (e.g. re-write with PowerShell `[IO.File]::WriteAllText` after normalizing).
- **ASCII only, no accented Hungarian, and avoid `!` in echoed text** — the script runs with `EnableDelayedExpansion`, which eats/mangles `!` in output strings.
- `diskpart` output parsing must accept both English and Hungarian tokens (`Disk`/`Lemez`, `Partition`/`Partíció` matched via `Part` prefix, `System`/`Rendszer`), and must filter header lines (they contain `###`).

## Architecture of BootFixer.cmd

- Main flow: admin check (`fltmc`) → `diskpart list disk` parse → per-disk enrichment (model via `wmic`, EFI partition via `list partition`, Windows drive mapping via `select volume <letter>` + `detail volume`) → interactive menu → `:FIXUEFI` or `:FIXLEGACY` → `:DONE`.
- Disk data lives in pseudo-arrays: `DNUM_n`, `DGPT_n`, `DSIZE_n`, `DMOD_n`, `DWIN_n`, `DEFI_n` (1-based index `n`, count in `DCOUNT`).
- Drive letter `X:` is deliberately skipped when searching for Windows installs — it is the WinPE ramdisk.
- All `diskpart` invocations go through temp script files (`%TMPD%\bf_dp.txt` in, `bf_out.txt` out).
- **`:SingleBoot` must always be called with an explicit BCD store path.** In WinPE the default `bcdedit` system store is the boot USB's own BCD — editing it without `/store` would wreck the Sergei stick, not fix the target machine. (Legacy path skips single-boot entirely if it couldn't mount the target boot partition.)
- MBR rewrite prefers `bootsect /nt60 <letter>: /mbr` (targets the selected disk explicitly); `bootrec /fixmbr` is only the fallback because it can hit the wrong disk on multi-disk systems.

## Testing without touching the real system

Live testing needs admin and would rewrite real boot config. Instead, dry-run with stub executables on `PATH` (pattern used and verified previously):

1. Compile tiny C# stubs with the framework compiler available on any Windows box: `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /out:diskpart.exe stub.cs` — stubs for `diskpart` (returns canned `list disk`/`detail volume`/`list partition` output based on the `/s` script content, and performs `subst`/`subst /d` for `assign letter=`/`remove letter=` to fake mounts), plus `fltmc`, `bcdedit` (canned `/enum` output), `bcdboot` (creates the fake BCD file), `bootsect`. Stubs append their args to a `calls.log` for assertion.
2. **Stubs must be `.exe`, not `.bat`** — a batch invoked from a batch without `call` never returns (the parent script dies silently).
3. Run with the stub dir prepended to PATH, stdin redirected from a file of menu answers (e.g. `1`, `i`, blank lines for `pause`), and assert on `calls.log`:
   `cmd /c "set PATH=<stubdir>;%PATH%& call <repo>\BootFixer.cmd < input.txt"`
   Note: invoke the script by full quoted path; `cd X & call BootFixer.cmd` fails to resolve it.
