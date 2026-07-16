# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file Windows boot repair tool (`BootFixer.cmd`) with a Hungarian text UI. It is run inside **WinPE (Sergei Strelec boot USB)** to repair the boot configuration of an installed Windows: it detects disks via `diskpart`, finds Windows installations, then rewrites boot files (`bcdboot`) and enforces single-boot (`bcdedit`) for either UEFI/GPT or Legacy/MBR disks. Each fixed disk becomes independently bootable (self-contained boot files on its own ESP / system partition), so multi-disk single-boot scenarios work by running the tool once per disk. On a GPT disk that has no EFI System Partition, it can create one by shrinking the Windows volume.

There is no build step, no tests, no dependencies. The `.cmd` file is the entire product; users copy it to a USB stick and run it as admin.

## Hard constraints

- **Pure batch only — no .NET, no compiled exe.** The tool previously was a C# exe (still in git history) and failed with `0xc0000135` in WinPE because WinPE has no .NET Framework. Everything must run with only what WinPE ships: `cmd`, `diskpart`, `bcdboot`, `bcdedit`, `bootsect`/`bootrec`, `findstr`, `ping`.
- **CRLF line endings are mandatory.** The file-writing tools emit LF-only files, and `cmd` silently mis-parses LF-only batch (symptom: chopped commands like `'et' is not recognized`, or labels not found). After any edit, ensure the file is CRLF (e.g. re-write with PowerShell `[IO.File]::WriteAllText` after normalizing).
- **ASCII only, no accented Hungarian, and avoid `!` in echoed text** — the script runs with `EnableDelayedExpansion`, which eats/mangles `!` in output strings.
- `diskpart` output parsing must accept both English and Hungarian tokens (`Disk`/`Lemez`, `Partition`/`Partíció` matched via `Part` prefix, `System`/`Rendszer`), and must filter header lines (they contain `###`).
- **GPT vs MBR is detected from `uniqueid disk`, not from the `*` in `list disk`.** GPT prints a GUID (`Disk ID: {…-XXXX-…}`), MBR an 8-hex signature. The old `find "*"` on the `list disk` line was wrong: both the `Gpt` and `Dyn` columns render `*`, so a dynamic MBR disk got misclassified as GPT. The GUID test uses regex `-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-`, which is locale-independent and immune to a hyphen in the machine name (only one dash).

## Architecture of BootFixer.cmd

- Main flow: admin check (`fltmc`) → `diskpart list disk` parse (`:AddDisk`) → per-disk enrichment: model via `wmic` (`:GetModel`), GPT/MBR via `uniqueid disk` (`:DetectGPT`), Windows drive mapping via `select volume <letter>` + `detail volume` (`:CheckWin`), EFI partition via `list partition` (`:FindEFI`) → interactive menu → `:FIXUEFI` or `:FIXLEGACY` → `:DONE`.
- Disk data lives in pseudo-arrays: `DNUM_n`, `DGPT_n`, `DSIZE_n`, `DMOD_n`, `DWIN_n`, `DEFI_n` (1-based index `n`, count in `DCOUNT`). After a disk is picked these are copied to scalars `SELNUM`/`SELGPT`/`SELEFI`/`SELWIN` etc.
- Drive letter `X:` is deliberately skipped when searching for Windows installs — it is the WinPE ramdisk.
- All `diskpart` invocations go through temp script files (`%TMPD%\bf_dp.txt` in, `bf_out.txt` out).
- **UEFI path can create a missing ESP** (`:CreateEFI`): if the selected GPT disk has no EFI System Partition (`SELEFI==0`), it prompts, then `shrink`s the Windows volume (~200 MB) and runs `create partition efi size=100` + `format fs=fat32`, then re-scans with `:FindEFISel`. This is the only destructive operation and is guarded by its own confirmation. If the shrink/create fails, `SELEFI` stays `0` and the flow aborts cleanly (no half-made partition).
- **Legacy path makes the Windows-bearing partition active, not blindly the first primary.** `:FindWinPart` reads `detail partition` for the Windows volume to get its partition number and prefers it; the old "first primary" heuristic is only the fallback. This avoids putting boot files on a data partition that happens to be partition 1.
- **`:SingleBoot` must always be called with an explicit BCD store path.** In WinPE the default `bcdedit` system store is the boot USB's own BCD — editing it without `/store` would wreck the Sergei stick, not fix the target machine. (Legacy path skips single-boot entirely if it couldn't mount the target boot partition.)
- **`:SingleBoot`/`:DelEntry` must not delete WinRE.** When pruning `osloader` entries it checks each entry's `device` line and skips any whose device is `ramdisk` (the Windows Recovery Environment) — deleting it would break "Reset this PC" / auto-repair. `ramdisk` is locale-independent so this works on any language.
- `ERRFLAG` tracks whether any `bcdboot` step reported an error; `:DONE` prints a warning banner instead of "success" when it is set. Keep setting it in any new failure branch so the final message stays honest.
- MBR rewrite prefers `bootsect /nt60 <letter>: /mbr` (targets the selected disk explicitly); `bootrec /fixmbr` is only the fallback because it can hit the wrong disk on multi-disk systems.

## Testing without touching the real system

Live testing needs admin and would rewrite real boot config. Instead, dry-run with stub executables on `PATH` (pattern used and verified previously):

1. Compile tiny C# stubs with the framework compiler available on any Windows box: `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /out:diskpart.exe stub.cs` — stubs for `diskpart` (returns canned `list disk`/`detail volume`/`list partition` output based on the `/s` script content, and performs `subst`/`subst /d` for `assign letter=`/`remove letter=` to fake mounts), plus `fltmc`, `bcdedit` (canned `/enum` output), `bcdboot` (creates the fake BCD file), `bootsect`. Stubs append their args to a `calls.log` for assertion.
2. **Stubs must be `.exe`, not `.bat`** — a batch invoked from a batch without `call` never returns (the parent script dies silently).
3. Run with the stub dir prepended to PATH, stdin redirected from a file of menu answers (e.g. `1`, `i`, blank lines for `pause`), and assert on `calls.log`:
   `cmd /c "set PATH=<stubdir>;%PATH%& call <repo>\BootFixer.cmd < input.txt"`
   Note: invoke the script by full quoted path; `cd X & call BootFixer.cmd` fails to resolve it.

For the fiddly *parsing* subroutines (`:DetectGPT` regex, `:DelEntry` ramdisk skip, `:FindEFISel`, `:GrabWinPart`) a full stub harness is overkill — instead copy the subroutine's `for /f`/`findstr` block into a throwaway `.cmd` that reads a **canned `diskpart`/`bcdedit` output text file** (real `cmd`+`findstr`, no disks involved) and print the resulting variable. This verifies the exact parse cheaply and covers both English and Hungarian fixtures. Two gotchas learned here: run these harnesses with `cmd /c "<absolute path>"` (the Bash-tool CWD resets between calls, so relative paths silently read the wrong/missing file), and never put literal parentheses inside an `echo` that sits inside an `if (...)`/`for (...)` block — cmd treats them as block delimiters and dies with `) was unexpected at this time`.
