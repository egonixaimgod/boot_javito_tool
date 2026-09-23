@echo off
setlocal EnableExtensions EnableDelayedExpansion
title BootFixer
rem =====================================================
rem   BOOTFIXER v8 - a boot particio ujrairasa
rem
rem   1. lemez kivalasztasa (azon a lemezen kell lennie a Windowsnak)
rem   2. boot mod: UEFI (GPT lemez) vagy Legacy BIOS (MBR lemez) -
rem      UEFI + MBR vagy Legacy + GPT felemas megoldast NEM csinal
rem   3. a lemez REGI boot particioinak torlese. Csak az torlodik, ami
rem      EFI tipusu VAGY boot fajlok vannak rajta, ES 1 GB-nal kisebb, ES
rem      nem a Windows particio. A megerosites tetelesen kiirja.
rem   4. UJ boot particio + boot fajlok (bcdboot), single boot
rem   5. UEFI + MBR lemez: elobb Legacy boot kerul ra, majd a Microsoft
rem      sajat mbr2gpt eszkoze alakitja GPT-re (elotte /validate - csak
rem      akkor alakit, ha o szerint biztonsagos). Legacy + GPT lemez: nincs
rem      biztonsagos eszkoz GPT-bol MBR-be, ezert nem csinalja.
rem
rem   WinPE-bol es masik, bootolhato Windowsbol is fut (a javitando lemez
rem   pl. USB-n csatlakoztatva). Minden lepes a logba kerul.
rem
rem   Szerkesztesnel: delayed expansion miatt a kiirt szovegben NINCS
rem   felkialtojel, es "->" sincs (a ">" atiranyitas). Tiszta batch,
rem   CRLF sorvegek, csak ASCII.
rem =====================================================

rem --- Temp konyvtar ---
set "TMPD=%TEMP%"
if not exist "%TMPD%" set "TMPD=X:\Windows\Temp"
if not exist "%TMPD%" set "TMPD=%SystemRoot%\Temp"
if not exist "%TMPD%" set "TMPD=%~dp0"
set "DPS=%TMPD%\bf_dp.txt"
set "DPO=%TMPD%\bf_out.txt"
set "DRV=%TMPD%\bf_drv.txt"

rem --- Log fajl: eloszor a script mappaja, ha az nem irhato, a temp ---
set "LOG=%~dp0bootfixer_log.txt"
(type nul >>"%LOG%") 2>nul || set "LOG=%TMPD%\bootfixer_log.txt"
>"%LOG%" echo ===== BootFixer v8 log - %DATE% %TIME% =====

rem --- Admin ellenorzes + UAC onfelemeles ---
rem WinPE alatt nincs UAC es minden eleve adminkent fut, de a fltmc ott
rem hibazhat - a csak WinPE-ben letezo MiniNT kulcsbol ismerjuk fel.
set "ISPE="
reg query HKLM\SYSTEM\CurrentControlSet\Control\MiniNT >nul 2>&1 && set "ISPE=1"
if defined ISPE goto AdminOK
fltmc >nul 2>&1
if not errorlevel 1 goto AdminOK
if /i "%~1"=="ELEV" (
    echo.
    echo   [HIBA] Rendszergazdai jog szukseges, de nem sikerult megszerezni.
    echo.
    pause
    exit /b 1
)
echo.
echo   [INFO] Nincs rendszergazdai jog - ujrainditas emelt joggal...
echo   [INFO] A felugro UAC ablakban valaszd az Igen gombot.
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -ArgumentList 'ELEV' -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }" >nul 2>&1
if errorlevel 1 (
    echo.
    echo   [HIBA] Az emelt jogu inditas nem sikerult vagy el lett utasitva.
    echo   Inditsd kezzel rendszergazdakent.
    echo.
    pause
    exit /b 1
)
exit /b 0
:AdminOK

rem --- Milyen modban indult a gep? Csak TIPP a valasztashoz. ---
if defined ISPE wpeutil UpdateBootInfo >nul 2>&1
set "FWMODE="
for /f "tokens=3" %%a in ('reg query HKLM\SYSTEM\CurrentControlSet\Control /v PEFirmwareType 2^>nul ^| find "0x"') do (
    if "%%a"=="0x1" set "FWMODE=Legacy BIOS"
    if "%%a"=="0x2" set "FWMODE=UEFI"
)
if not defined FWMODE (
    for /f "delims=" %%a in ('bcdedit /enum {current} 2^>nul ^| find /i "winload."') do (
        echo %%a | find /i ".efi" >nul && set "FWMODE=UEFI"
        echo %%a | find /i ".exe" >nul && set "FWMODE=Legacy BIOS"
    )
)
>>"%LOG%" echo Futo firmware mod: %FWMODE%  WinPE=%ISPE%

cls
echo.
echo   =============================
echo        B O O T F I X E R
echo        v8 - boot particio
echo   =============================
echo.
echo   Log: %LOG%
if defined FWMODE echo   A gep most %FWMODE% modban indult.
echo.
echo   Lemezek keresese...
echo.

rem =====================================================
rem   LEMEZEK FELDERITESE
rem =====================================================
>"%DPS%" echo list disk
call :DPRun
if not exist "%DPO%" goto DPFAIL
findstr /r /c:"[0-9]" "%DPO%" >nul 2>&1 || goto DPFAIL

set /a DCOUNT=0
for /f "usebackq delims=" %%L in (`findstr /r /c:"Disk [0-9]" /c:"Lemez [0-9]" "%DPO%" ^| findstr /v /c:"###"`) do (
    set "LINE=%%L"
    call :AddDisk
)

if %DCOUNT%==0 (
    echo   Nem talalhato lemez.
    echo.
    echo   [Debug] Diskpart kimenet:
    type "%DPO%"
    goto END
)

for /L %%i in (1,1,%DCOUNT%) do call :GetModel %%i
for /L %%i in (1,1,%DCOUNT%) do call :DetectGPT %%i
rem Windows telepitesek keresese (X: kihagyva, az a WinPE)
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do call :CheckWin %%D

rem =====================================================
rem   1. LEMEZ KIVALASZTASA
rem =====================================================
:PICKDISK
echo   Talalt lemezek:
echo   -------------------------------------------------------
for /L %%i in (1,1,%DCOUNT%) do (
    set "BT=MBR"
    if "!DGPT_%%i!"=="1" set "BT=GPT"
    set "WT=nincs rajta Windows"
    if !DWCNT_%%i! GTR 0 set "WT=Windows:!DWIN_%%i!"
    echo   [%%i] !DMOD_%%i! ^| !DSIZE_%%i! ^| !BT! ^| !WT!
)
echo.
echo   [0] Kilepes
echo.
set "CH="
set /p "CH=  Melyik lemez bootjat irjam ujra? [szam]: "
if not defined CH goto END
if "!CH!"=="0" goto END
call :IsNum CH
if not defined ISNUM goto BADDISK
if !CH! LSS 1 goto BADDISK
if !CH! GTR %DCOUNT% goto BADDISK

set "SELNUM=!DNUM_%CH%!"
set "SELGPT=!DGPT_%CH%!"
set "SELMOD=!DMOD_%CH%!"
set "SELSIZE=!DSIZE_%CH%!"
set "SELBPS=!DBPS_%CH%!"
set "WLIST=!DWIN_%CH%!"
set "WCNT=!DWCNT_%CH%!"
set "PSTYLE=MBR"
if "%SELGPT%"=="1" set "PSTYLE=GPT"

if "%WCNT%"=="0" (
    echo.
    echo   [HIBA] Ezen a lemezen nincs Windows - nincs mit elinditani rola.
    echo          Valassz olyan lemezt, amelyiken a Windows van.
    echo.
    goto PICKDISK
)

rem Teljes Windowsban a futo rendszer sajat lemezet nem javitjuk: annak mar
rem van mukodo bootja, es futas kozben irnank at. A csatlakoztatott masik
rem lemezt (pl. USB-n) ez nem erinti.
set "RUNDISK="
if not defined ISPE for %%w in (%WLIST%) do if /i "%%w"=="%SystemDrive%" set "RUNDISK=1"
if defined RUNDISK (
    echo.
    echo   [HIBA] Ezen a lemezen fut a mostani Windows - azt innen nem javitom.
    echo          Valaszd a javitando lemezt, vagy inditsd a gepet WinPE-rol.
    echo.
    goto PICKDISK
)

set "SELWIN="
if "%WCNT%"=="1" (
    for %%w in (%WLIST%) do set "SELWIN=%%w"
) else (
    call :AskWin
)
if not defined SELWIN goto END
set "SELWIN=%SELWIN:~0,1%"

rem =====================================================
rem   2. BOOT MOD KIVALASZTASA
rem =====================================================
:ASKMODE
echo.
echo   Milyen boot legyen?
echo     [1] UEFI         - GPT lemez
echo     [2] Legacy BIOS  - MBR lemez
if defined FWMODE echo   Tipp: ez a gep most %FWMODE% modban indult - altalaban ezt erdemes valasztani.
echo     [0] Kilepes
set "MD="
set /p "MD=  Valasztas [1/2]: "
if "!MD!"=="1" goto MODEUEFI
if "!MD!"=="2" goto MODELEG
if "!MD!"=="0" goto END
echo   Ervenytelen valasztas.
goto ASKMODE

:MODEUEFI
set "FINALFW=UEFI"
set "VIAM2G="
if "%SELGPT%"=="1" (
    set "BCDFW=UEFI"
    set "PTYPE=efi"
    set "FS=fat32"
    set "ACTIVE="
    set "SIZE=300"
    set "MINSZ=260"
    if "!SELBPS!"=="512" set "SIZE=100"
    if "!SELBPS!"=="512" set "MINSZ=100"
    set "MODE=UEFI - GPT lemez"
    goto PLAN
)
rem MBR lemez: UEFI-hez GPT kell. Az mbr2gpt a lemezen levo boot-
rem beallitasbol talalja meg a Windowst, ezert elobb Legacy boot kerul ra.
call :FindM2G
if not defined M2G (
    echo.
    echo   [HIBA] Ez MBR lemez - UEFI-hez GPT-re kell alakitani, de az mbr2gpt nem talalhato.
    echo          Windows 10 1703 vagy ujabb kell hozza - futtasd egy ilyen Windowsbol.
    goto ASKMODE
)
set "VIAM2G=1"
set "BCDFW=BIOS"
set "PTYPE=primary"
set "FS=ntfs"
set "ACTIVE=1"
set "SIZE=300"
set "MINSZ=100"
set "MODE=UEFI - GPT, a lemez atalakitasa a Microsoft mbr2gpt eszkozevel"
goto PLAN

:MODELEG
if "%SELGPT%"=="1" (
    echo.
    echo   [HIBA] Ez GPT lemez - Legacy BIOS-bol GPT lemezrol a Windows nem indul,
    echo          GPT-rol MBR-re pedig nincs biztonsagos, adatvesztes nelkuli eszkoz.
    echo          Ezt a lemezt UEFI boottal lehet inditani - valaszd az 1-est.
    goto ASKMODE
)
set "FINALFW=BIOS"
set "VIAM2G="
set "BCDFW=BIOS"
set "PTYPE=primary"
set "FS=ntfs"
set "ACTIVE=1"
set "SIZE=500"
set "MINSZ=100"
set "MODE=Legacy BIOS - MBR lemez"
goto PLAN

rem =====================================================
rem   3. REGI BOOT PARTICIOK FELMERESE (meg nem torol semmit)
rem =====================================================
:PLAN
set /a SHR=SIZE+16
echo.
echo   A lemez particioinak felmerese...
call :FindWinPart
if not defined WINPART (
    echo   [HIBA] Nem allapithato meg, melyik particion van a Windows.
    echo          Biztonsagbol leallok - nem torlok es nem irok semmit.
    goto FAIL
)
>>"%LOG%" echo A Windows particio szama: %WINPART%
call :FindBootParts

rem =====================================================
rem   MEGEROSITES
rem =====================================================
echo.
echo   ===================================================
echo     Lemez:     !SELMOD! ^| !SELSIZE! ^| %PSTYLE%
echo     Windows:   %SELWIN%:\Windows - particio %WINPART%
echo     Boot mod:  %MODE%
echo   ===================================================
echo   Ezt fogom csinalni:
if defined DELLIST (
    echo     1. A lemez REGI boot particioinak TORLESE:
    for %%p in (%DELLIST%) do echo          - !DELDESC_%%p!
) else (
    echo     1. Regi boot particio nincs a lemezen - nincs mit torolni.
)
if defined KEPTLIST (
    echo        NEM torlom, mert mas fajlok is vannak rajta:
    for %%p in (%KEPTLIST%) do echo          - !KEPTDESC_%%p!
)
echo     2. Uj boot particio, %FS% fajlrendszerrel - ures resz nem marad:
echo        ha a lemez elejen van szabad hely, azt tolti ki, kulonben
echo        %SIZE% MB-ot kap kozvetlenul a Windows mogott.
echo     3. Boot fajlok irasa a %SELWIN%:\Windows-bol, single boot.
if defined VIAM2G (
    echo     4. A lemez atalakitasa GPT-re a Microsoft mbr2gpt eszkozevel.
    echo        Elobb csak ellenoriz - ha nem engedi, megallok, es a lemez
    echo        akkor Legacy BIOS modban indul. Utana az ideiglenes Legacy
    echo        particiot torlom, es az EFI particiot a vegleges helyere irom.
)
echo     A Windows a vegen atveszi a kozvetlenul mogotte levo szabad helyet.
echo   A Windows particiohoz nem nyulok.
echo.
set "CONF="
set /p "CONF=  Folytatod? (i/n): "
if /i not "!CONF!"=="i" (
    echo   Megszakitva.
    goto END
)
>>"%LOG%" echo.
>>"%LOG%" echo ===== VALASZTAS: lemez=%SELNUM% [!SELMOD!] %PSTYLE%, Windows=%SELWIN%: particio %WINPART%, mod=%MODE%, torles=[%DELLIST%], uj=%PTYPE% %SIZE% MB %FS% =====
set "CHANGED="
set "PASS2="

rem =====================================================
rem   4. REGI BOOT PARTICIOK TORLESE
rem =====================================================
if defined DELLIST (
    echo.
    echo   Regi boot particiok torlese...
    call :DeleteBootParts
)
if defined DELFAIL goto FAIL

rem =====================================================
rem   5. UJ BOOT PARTICIO
rem =====================================================
:BUILD
echo.
echo   Uj boot particio letrehozasa...
call :MakeBootPart
if defined MKHALF goto PARTHALF
if defined MKFAIL goto FAIL
goto PARTOK

:PARTHALF
set "CHANGED=1"
echo   [HIBA] A particio letrejott, de a formazas vagy a betujel kiosztasa nem sikerult.
echo   Diskpart uzenete:
type "%DPO%"
echo.
echo   A felig kesz particiot a Lemezkezeloben torolheted, utana futtasd ujra ezt a scriptet.
goto FAIL

:PARTOK
set "CHANGED=1"
if defined NEWPART (
    echo   [OK] Uj boot particio kesz: %BL%: - lemez %SELNUM%, particio %NEWPART%
) else (
    echo   [OK] Uj boot particio kesz: %BL%:
)

rem =====================================================
rem   6. BOOT FAJLOK
rem =====================================================
echo   Boot fajlok irasa...
set "BOOTERR="
set "NOBOOTSECT="
if "%BCDFW%"=="BIOS" call :WriteMbr
call :RunBcdboot
if not "%RC%"=="0" (
    echo   [HIBA] A bcdboot hibat jelzett. Kimenete:
    type "%DPO%"
    set "BOOTERR=1"
)

rem A verdikt nem a visszateresi kod, hanem hogy a fajlok tenyleg ott vannak.
if "%BCDFW%"=="UEFI" (
    set "CHK1=%BL%:\EFI\Microsoft\Boot\BCD"
    set "CHK2=%BL%:\EFI\Microsoft\Boot\bootmgfw.efi"
) else (
    set "CHK1=%BL%:\Boot\BCD"
    set "CHK2=%BL%:\bootmgr"
)
set "MISSING="
if not exist "%CHK1%" set "MISSING=%CHK1%"
if not exist "%CHK2%" set "MISSING=%MISSING% %CHK2%"
if defined MISSING (
    echo   [HIBA] Hianyzo boot fajl az uj particion: %MISSING%
    >>"%LOG%" echo ELLENORZES: hianyzik: %MISSING%
    set "BOOTERR=1"
) else (
    echo   [OK] Boot fajlok a helyukon.
    >>"%LOG%" echo ELLENORZES: %CHK1% es %CHK2% megvan.
    call :SingleBoot "%CHK1%"
)

rem Betujel levetele az uj particiorol
>"%DPS%" (
    echo select disk %SELNUM%
    if defined NEWPART (echo select partition %NEWPART%) else (echo select volume %BL%)
    echo remove letter=%BL%
)
call :DPRun
if defined BOOTERR goto DONE

rem =====================================================
rem   7. MBR lemez + UEFI: atalakitas GPT-re (mbr2gpt)
rem =====================================================
set "M2GFAIL="
if not defined VIAM2G goto FINISH
call :DoM2G
if defined M2GFAIL goto FINISH
rem Sikeres atalakitas: az mbr2gpt a Windows MOGE tette az EFI particiot, az
rem ideiglenes Legacy particio pedig feleslegesen ott maradt (terepen merve).
rem Masodik kor, a mar tesztelt GPT-UEFI uton: mindkettot toroljuk, es az EFI
rem particio a vegleges helyere kerul - igy nem marad ures resz.
set "VIAM2G="
set "PASS2=1"
set "SELGPT=1"
set "PSTYLE=GPT"
set "BCDFW=UEFI"
set "PTYPE=efi"
set "FS=fat32"
set "ACTIVE="
set "SIZE=300"
set "MINSZ=260"
if "%SELBPS%"=="512" set "SIZE=100"
if "%SELBPS%"=="512" set "MINSZ=100"
echo.
echo   Az EFI particio vegleges helyre irasa...
call :FindWinPart
if not defined WINPART (
    echo   [FIGYELEM] A Windows particio nem azonosithato - az mbr2gpt EFI particioja marad.
    goto FINISH
)
call :FindBootParts
if defined DELLIST call :DeleteBootParts
if defined DELFAIL goto FAIL
goto BUILD

:FINISH
call :ExtendWin
call :DiskFree
goto DONE

rem =====================================================
rem   KESZ
rem =====================================================
:DONE
echo.
if defined BOOTERR (
    echo   ===================================================
    echo     A PARTICIO ELKESZULT, DE A BOOT FAJLOK IRASA HIBAS.
    echo     Ne inditsd ujra, amig a fenti hibat meg nem nezted.
    echo   ===================================================
    echo.
    echo   Reszletes log: %LOG%
    goto END
)
if defined M2GFAIL (
    echo   ===================================================
    echo     UEFI - GPT NEM LETT: az mbr2gpt nem alakitotta at a lemezt.
    echo     A lemez most Legacy BIOS modban bootolhato - MBR, aktiv boot particio.
    echo   ===================================================
    if defined NOBOOTSECT (
        echo   [FIGYELEM] A bootsect itt nem erheto el, az MBR boot kod nem lett ujrairva.
        echo              Ha Legacy modban nem indul, futtasd ujra WinPE-bol, Legacy modot valasztva.
    )
    echo.
    echo   Reszletes log: %LOG%
    goto END
)
echo   ===================================================
echo     KESZ: %MODE%
echo   ===================================================
echo.
echo   Mielott ujrainditasz, a gep BIOS-aban:
if "%FINALFW%"=="UEFI" (
    echo     - a boot mod legyen UEFI, CSM/Legacy KI
    echo     - a boot sorrendben a Windows Boot Manager legyen elol
) else (
    echo     - a boot mod legyen Legacy/CSM
    echo     - ez a lemez legyen az elso a boot sorrendben
)
echo     - a SATA mod maradjon azon, amin a Windows telepult - altalaban AHCI.
echo       Ha RAID-re vagy IDE-re allitod, a Windows INACCESSIBLE_BOOT_DEVICE hibaval all le.
if "%FINALFW%"=="BIOS" if defined NOBOOTSECT (
    echo   [FIGYELEM] A bootsect itt nem erheto el, az MBR boot kod nem lett ujrairva.
    echo              Ha Legacy modban nem indul, futtasd ujra WinPE-bol.
)
if "%FINALFW%"=="UEFI" if not defined ISPE (
    echo.
    echo   [INFO] UEFI modban a boot eszkoz ennek a gepnek - amin most futtattad - a boot
    echo          bejegyzeset is atallithatja az uj lemezre. Ha ez a gep utana nem indulna,
    echo          a sajat Windowsabol vagy WinPE-bol ez visszaallitja: bcdboot C:\Windows
)
echo.
echo   Reszletes log: %LOG%
goto END

:BADDISK
echo   Ervenytelen valasztas.
echo.
goto PICKDISK

:FAIL
echo.
echo   ===================================================
echo     NEM SIKERULT.
if defined CHANGED (
    echo     A lemezen mar tortent valtozas - a fenti uzenetek es a
    echo     log mondjak meg, pontosan mi.
) else (
    echo     A lemezen nem valtozott semmi.
)
echo   ===================================================
if defined PASS2 (
    echo   A lemez mar GPT. Futtasd ujra ezt a scriptet, UEFI-t valasztva -
    echo   az ujra megirja az EFI particiot.
)
echo   Reszletes log: %LOG%
goto END

:DPFAIL
echo   [HIBA] Diskpart nem erheto el vagy nem adott ertelmes kimenetet.
if exist "%DPO%" type "%DPO%"
echo   Reszletes log: %LOG%
goto END

:END
del "%DPS%" >nul 2>&1
del "%DPO%" >nul 2>&1
del "%DRV%" >nul 2>&1
echo.
pause
exit /b 0

rem =====================================================
rem   SZUBRUTINOK
rem =====================================================

:DPRun
rem diskpart futtatasa a %DPS% szkripttel; kimenet a %DPO%-ba es a logba.
rem DPRC = a diskpart kilepesi kodja (0 = minden parancs sikerult).
>>"%LOG%" echo.
>>"%LOG%" echo ===== diskpart =====
type "%DPS%" >>"%LOG%" 2>nul
>>"%LOG%" echo ----- kimenet -----
diskpart /s "%DPS%" >"%DPO%" 2>&1
set "DPRC=%ERRORLEVEL%"
type "%DPO%" >>"%LOG%" 2>nul
>>"%LOG%" echo ----- diskpart kilepesi kod: %DPRC% -----
goto :eof

:LogDPO
rem A %DPO% tartalmat a logba fuzi %1 cimkevel (nem-diskpart eszkozokhoz).
>>"%LOG%" echo.
>>"%LOG%" echo ===== %~1 =====
type "%DPO%" >>"%LOG%" 2>nul
goto :eof

:IsNum
rem ISNUM=1, ha a %1 nevu valtozo csak szamjegyekbol all.
set "ISNUM="
set "IV=!%~1!"
if not defined IV goto :eof
set "ISNUM=1"
for /f "delims=0123456789" %%x in ("!IV!") do set "ISNUM="
goto :eof

:AddDisk
rem !LINE! = pl. "  Disk 0    Online          931 GB      0 B         *"
set "DN=" & set "DS1=" & set "DS2="
for /f "tokens=1-5" %%a in ("!LINE!") do (
    set "DN=%%b"
    set "DS1=%%d"
    set "DS2=%%e"
)
call :IsNum DN
if not defined ISNUM goto :eof
set /a DCOUNT+=1
set "DNUM_%DCOUNT%=%DN%"
set "DGPT_%DCOUNT%=0"
set "DSIZE_%DCOUNT%=%DS1% %DS2%"
set "DMOD_%DCOUNT%=Lemez %DN%"
set "DBPS_%DCOUNT%="
set "DWIN_%DCOUNT%="
set "DWCNT_%DCOUNT%=0"
goto :eof

:GetModel
rem Lemez modellnev es szektormeret (wmic - opcionalis, uj Windowson hianyozhat;
rem szektormeret nelkul az EFI particio 300 MB lesz, ami minden lemezen jo).
set "N=!DNUM_%1!"
for /f "tokens=1* delims==" %%a in ('wmic diskdrive where "Index=%N%" get Model /value 2^>nul ^| find "="') do (
    for /f "delims=" %%c in ("%%b") do if not "%%c"=="" set "DMOD_%1=%%c"
)
for /f "tokens=1* delims==" %%a in ('wmic diskdrive where "Index=%N%" get BytesPerSector /value 2^>nul ^| find "="') do (
    for /f "delims=" %%c in ("%%b") do if not "%%c"=="" set "DBPS_%1=%%c"
)
goto :eof

:DetectGPT
rem GPT vs MBR: uniqueid disk -> GPT = GUID (kotojeles), MBR = 8 jegyu hex.
set "N=!DNUM_%1!"
>"%DPS%" (
    echo select disk %N%
    echo uniqueid disk
)
call :DPRun
findstr /r /c:"-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-" "%DPO%" >nul 2>&1 && set "DGPT_%1=1"
goto :eof

:CheckWin
rem Van-e Windows a %1 betun, es ha igen, melyik lemezen van.
set "WL=%1"
set "HASWIN="
if exist "%WL%:\Windows\System32\winload.exe" set "HASWIN=1"
if exist "%WL%:\Windows\System32\winload.efi" set "HASWIN=1"
if not defined HASWIN goto :eof
>"%DPS%" (
    echo select volume %WL%
    echo detail volume
)
call :DPRun
set "WDN="
for /f "usebackq tokens=1-3" %%a in (`findstr /r /c:"Disk [0-9]" /c:"Lemez [0-9]" "%DPO%" ^| findstr /v /c:"###"`) do (
    if /i "%%a"=="Disk" set "WDN=%%b"
    if /i "%%a"=="Lemez" set "WDN=%%b"
    if /i "%%b"=="Disk" set "WDN=%%c"
    if /i "%%b"=="Lemez" set "WDN=%%c"
)
if not defined WDN goto :eof
for /L %%i in (1,1,%DCOUNT%) do (
    if "!DNUM_%%i!"=="%WDN%" (
        set "DWIN_%%i=!DWIN_%%i! %WL%:"
        set /a DWCNT_%%i+=1
    )
)
>>"%LOG%" echo Windows talalva: %WL%: - lemez %WDN%
goto :eof

:AskWin
rem Tobb Windows egy lemezen - melyiket inditsa az uj boot?
echo.
echo   Tobb Windows is van ezen a lemezen:
set /a K=0
for %%w in (%WLIST%) do (
    set /a K+=1
    set "WOPT_!K!=%%w"
    echo     [!K!] %%w\Windows
)
set "WC="
set /p "WC=  Melyiket inditsa a gep? [szam]: "
call :IsNum WC
if not defined ISNUM goto :eof
if defined WOPT_%WC% set "SELWIN=!WOPT_%WC%!"
goto :eof

:FindM2G
rem mbr2gpt helye: a futo rendszer System32-je, kulonben a PATH.
set "M2G="
if exist "%SystemRoot%\System32\mbr2gpt.exe" set "M2G=%SystemRoot%\System32\mbr2gpt.exe"
if defined M2G goto :eof
for /f "delims=" %%m in ('where mbr2gpt.exe 2^>nul') do if not defined M2G set "M2G=%%m"
goto :eof

:FindWinPart
rem WINPART = a Windows kotet particioszama. Alaplemezen a "select volume"
rem a hozza tartozo particiot is kijeloli, a "detail partition" elso sora
rem "Partition N" (magyarul "Particio N" - mindketto "Part"-tal kezdodik).
rem Ha nem derul ki, WINPART ures marad, es a hivo leall.
set "WINPART="
>"%DPS%" (
    echo select volume %SELWIN%
    echo detail partition
)
call :DPRun
if not "%DPRC%"=="0" goto :eof
for /f "usebackq tokens=1,2" %%a in ("%DPO%") do if not defined WINPART call :WinPartLine "%%a" "%%b"
goto :eof

:WinPartLine
set "W1=%~1"
set "W2=%~2"
if /i not "!W1:~0,4!"=="Part" goto :eof
call :IsNum W2
if defined ISNUM set "WINPART=!W2!"
goto :eof

:FindBootParts
rem A lemez particioinak vegignezese; DELLIST = a torlendo boot particiok
rem szamai CSOKKENO sorrendben (a nagyobb szam torlese nem szamozza at a
rem kisebbeket). A Windows particio SOHA nem kerulhet bele.
set "DELLIST="
set "KEPTLIST="
call :ListParts
for %%p in (%PNUMS%) do if not "%%p"=="%WINPART%" call :ClassifyPart %%p
if defined DELLIST (
    >>"%LOG%" echo Torlendo regi boot particiok: %DELLIST%
) else (
    >>"%LOG%" echo Regi boot particio nem talalhato.
)
goto :eof

:ClassifyPart
rem %1 = particioszam. Boot particio, ha 1 GB-nal kisebb, ES EFI tipusu
rem VAGY boot fajlok vannak rajta. Minden dontes a logba kerul.
set "CP=%1"
set "CS=!PSIZE_%1!"
set "CU=!PUNIT_%1!"
rem Merethatar 1 GB: a Windows Legacy "System Reserved"-je 500-549 MB, egyes
rem gyartok EFI particioja 500-650 MB - ennel nagyobb boot particio nincs.
set "SMALL="
if /i "!CU!"=="KB" set "SMALL=1"
if /i "!CU!"=="MB" if !CS! LSS 1024 set "SMALL=1"
if not defined SMALL (
    >>"%LOG%" echo Particio %1 [!CS! !CU!]: nagy, nem boot particio - marad.
    goto :eof
)
set "ISB="
set "WHY="
set "TMPL="
>"%DPS%" (
    echo select disk %SELNUM%
    echo select partition %1
    echo detail partition
)
call :DPRun
if not "%DPRC%"=="0" (
    >>"%LOG%" echo Particio %1: detail partition hiba - marad.
    goto :eof
)
findstr /i /c:"c12a7328" "%DPO%" >nul 2>&1 && set "ISB=1" && set "WHY=EFI rendszerparticio"
findstr /i /r /c:": *ef *$" "%DPO%" >nul 2>&1 && set "ISB=1" && set "WHY=EFI tipusu particio"
rem Meglevo betujel a kotet-sorbol: "* Volume 3   E   SYSTEM   FAT32 ..."
set "EXL="
for /f "usebackq tokens=1-4" %%a in ("%DPO%") do if "%%a"=="*" call :VolLetter "%%c" "%%d"
if not defined EXL (
    call :FreeLetter
    if defined BL (
        >"%DPS%" (
            echo select disk %SELNUM%
            echo select partition %1
            echo assign letter=!BL!
        )
        call :DPRun
        call :Sleep 2
        if exist !BL!:\ (
            set "EXL=!BL!"
            set "TMPL=!BL!"
        )
    )
)
if defined EXL (
    if /i "!EXL!"=="%SELWIN%" (
        >>"%LOG%" echo Particio %1: ez a Windows kotete - marad.
        set "ISB="
        goto ClassifyEnd
    )
    if exist "!EXL!:\bootmgr" set "ISB=1" & set "WHY=Legacy boot particio - bootmgr"
    if exist "!EXL!:\Boot\BCD" set "ISB=1" & set "WHY=Legacy boot particio - Boot\BCD"
    if exist "!EXL!:\EFI\Microsoft\Boot\BCD" set "ISB=1" & set "WHY=EFI boot fajlok"
    if exist "!EXL!:\EFI\Boot\bootx64.efi" set "ISB=1" & set "WHY=EFI boot fajlok"
)
rem Adatvedelem: ha a boot fajlok mellett BARMI MAS is van a gyokerben,
rem nem toroljuk - a megerosites nevesiti, mi van rajta.
set "OTHERS="
if defined EXL if defined ISB call :CheckRoot !EXL!
if defined OTHERS (
    set "ISB="
    set "KEPTLIST=!KEPTLIST! %CP%"
    set "KEPTDESC_%CP%=particio %CP%, !CS! !CU! - a boot fajlok mellett mas is van rajta:!OTHERS!"
    >>"%LOG%" echo Particio %CP%: boot fajlok mellett egyeb elemek:!OTHERS! - NEM toroljuk.
)
:ClassifyEnd
if defined TMPL (
    >"%DPS%" (
        echo select disk %SELNUM%
        echo select partition %CP%
        echo remove letter=!TMPL!
    )
    call :DPRun
)
if defined ISB (
    set "DELLIST=%CP% !DELLIST!"
    set "DELDESC_%CP%=particio %CP%, !CS! !CU! - !WHY!"
    >>"%LOG%" echo Particio %CP% [!CS! !CU!]: BOOT PARTICIO - !WHY! - torlendo.
) else (
    >>"%LOG%" echo Particio %CP% [!CS! !CU!]: nem boot particio - marad.
)
goto :eof

:CheckRoot
rem OTHERS = a %1: gyokereben levo, NEM boot-jellegu elemek listaja.
rem Rejtett/rendszer elemeket is nez (dir /a). Ures lista = csak boot van rajta.
set "OTHERS="
for /f "delims=" %%n in ('dir /a /b "%~1:\" 2^>nul') do call :RootItem "%%n"
goto :eof

:RootItem
set "RI=%~1"
for %%k in ("EFI" "Boot" "bootmgr" "BOOTNXT" "BOOTSECT.BAK" "bootmgr.efi" "System Volume Information" "$RECYCLE.BIN" "Recovery" "$WINRE_BACKUP_PARTITION.MARKER") do if /i "!RI!"=="%%~k" goto :eof
set "OTHERS=!OTHERS! [!RI!]"
goto :eof

:VolLetter
rem A kotet-sor 3. tokenje a kotet szama, a 4. a betu (ha egyetlen karakter).
set "V3=%~1"
set "V4=%~2"
call :IsNum V3
if not defined ISNUM goto :eof
if not "!V4:~1!"=="" goto :eof
for %%L in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do if /i "!V4!"=="%%L" set "EXL=%%L"
goto :eof

:DeleteBootParts
rem A DELLIST csokkeno sorrendu. Minden torles elott ujra ellenorizzuk,
rem hogy nem a Windows particio / kotet.
set "DELFAIL="
for %%p in (%DELLIST%) do if not defined DELFAIL call :DelOne %%p
goto :eof

:DelOne
if "%1"=="%WINPART%" (
    echo   [HIBA] A torlesi lista a Windows particiot tartalmazna - leallok.
    set "DELFAIL=1"
    goto :eof
)
>"%DPS%" (
    echo select disk %SELNUM%
    echo select partition %1
    echo detail partition
)
call :DPRun
set "EXL="
for /f "usebackq tokens=1-4" %%a in ("%DPO%") do if "%%a"=="*" call :VolLetter "%%c" "%%d"
if /i "!EXL!"=="%SELWIN%" (
    echo   [HIBA] A %1. particio a Windows kotete - nem torlom, leallok.
    set "DELFAIL=1"
    goto :eof
)
>"%DPS%" (
    echo select disk %SELNUM%
    echo select partition %1
    echo delete partition override
)
call :DPRun
if "%DPRC%"=="0" (
    echo   [OK] Torolve: !DELDESC_%1!
    set "CHANGED=1"
) else (
    echo   [HIBA] Nem sikerult torolni: !DELDESC_%1! - diskpart uzenete:
    type "%DPO%"
    set "DELFAIL=1"
)
goto :eof

:FreeLetter
rem Szabad betu keresese. Az "exist" egy ures CD-meghajtot szabadnak latna,
rem ezert az fsutil listajat is nezzuk (kimenet: "Drives: C:\ D:\ ...").
set "BL="
fsutil fsinfo drives >"%DRV%" 2>nul
for %%L in (S R Q P O N M L K) do if not defined BL (
    if not exist %%L:\ (
        findstr /l /c:" %%L:" "%DRV%" >nul 2>&1 || set "BL=%%L"
    )
)
goto :eof

:ListParts
rem PCOUNT = particiok szama, PNUMS = a szamaik, PSIZE_n / PUNIT_n = meretuk.
rem Lokalizacio-fuggetlen: "Partition N" es "Particio N" is "Part"-tal kezdodik.
>"%DPS%" (
    echo select disk %SELNUM%
    echo list partition
)
call :DPRun
set /a PCOUNT=0
set "PNUMS="
set /a MINOFF=2000000000
for /f "usebackq tokens=1-8" %%a in ("%DPO%") do call :PartLine "%%a" "%%b" "%%c" "%%d" "%%e" "%%f" "%%g" "%%h"
>>"%LOG%" echo Particiok a %SELNUM%. lemezen: [%PNUMS%] - %PCOUNT% db, az elso kezdete: %MINOFF% MB
goto :eof

:PartLine
rem "  Partition 2    System   100 MB  1024 KB"  vagy csillaggal az elejen.
rem Tokenek: Part N Tipus Meret Egyseg Kezdet Egyseg.
set "L1=%~1"
set "L2=%~2"
set "L4=%~4"
set "L5=%~5"
set "L6=%~6"
set "L7=%~7"
if "!L1!"=="*" (
    set "L1=%~2"
    set "L2=%~3"
    set "L4=%~5"
    set "L5=%~6"
    set "L6=%~7"
    set "L7=%~8"
)
if /i not "!L1:~0,4!"=="Part" goto :eof
call :IsNum L2
if not defined ISNUM goto :eof
set /a PCOUNT+=1
set "PNUMS=!PNUMS! !L2!"
set "PSIZE_!L2!=!L4!"
set "PUNIT_!L2!=!L5!"
rem Kezdet MB-ban (a lemez eleji ures resz meresehez)
set "OFFMB="
call :IsNum L6
if defined ISNUM (
    if /i "!L7!"=="KB" set /a OFFMB=L6/1024
    if /i "!L7!"=="MB" set /a OFFMB=L6
    if /i "!L7!"=="GB" set /a OFFMB=L6*1024
    if /i "!L7!"=="TB" set /a OFFMB=L6*1048576
)
if defined OFFMB if !OFFMB! LSS !MINOFF! set /a MINOFF=OFFMB
goto :eof

:CreatePart
rem Microsoft sajat WinPE mintaszkriptjeinek sorrendje:
rem create -> format -> assign [-> active]. A vegen a "list partition"
rem csillaggal jeloli a fokuszban levot = az imen letrehozott particiot.
rem Ha a create elbukik, a diskpart ott megall, es semmi nem valtozik.
rem Cimke: NTFS-en "System Reserved" (mint a Windows telepitonel), az EFI
rem particio cimke nelkul.
rem CRSIZE = meret MB-ban (ures: kitolti a reszt), CROFF = kezdet KB-ban (ures:
rem az elso eleg nagy szabad resz).
set "NEWPART="
set "CRCMD=create partition %PTYPE%"
if defined CRSIZE set "CRCMD=!CRCMD! size=!CRSIZE!"
if defined CROFF set "CRCMD=!CRCMD! offset=!CROFF!"
>"%DPS%" (
    echo select disk %SELNUM%
    echo !CRCMD!
    if "%FS%"=="ntfs" (echo format quick fs=ntfs label="System Reserved") else (echo format quick fs=%FS%)
    echo assign letter=%BL%
    if defined ACTIVE echo active
    echo list partition
)
call :DPRun
for /f "usebackq tokens=1-3" %%a in ("%DPO%") do (
    if "%%a"=="*" call :StarLine "%%b" "%%c"
)
call :Sleep 3
goto :eof

:StarLine
set "S1=%~1"
if /i "!S1:~0,4!"=="Part" set "NEWPART=%~2"
goto :eof

:WriteMbr
rem Legacy: uj MBR boot kod + a particio boot szektora. A bootsect csak
rem WinPE-ben / telepito media-n van; teljes Windowson hianyozhat.
set "NOBOOTSECT="
where bootsect >nul 2>&1
if errorlevel 1 (
    set "NOBOOTSECT=1"
    >>"%LOG%" echo bootsect nem elerheto - az MBR boot kod nem lett ujrairva
    goto :eof
)
bootsect /nt60 %BL%: /mbr >"%DPO%" 2>&1
set "RC=%ERRORLEVEL%"
call :LogDPO "bootsect /nt60 %BL%: /mbr - rc=%RC%"
if "%RC%"=="0" (
    echo   [OK] MBR boot kod ujrairva.
) else (
    echo   [FIGYELEM] A bootsect hibat jelzett:
    type "%DPO%"
)
goto :eof

:RunBcdboot
rem Eloszor a CEL-Windows sajat bcdboot-ja (az illik a verziojahoz), utana a
rem futo rendszere. Mindkettot hu-HU nyelvvel, majd anelkul. RC=0 = siker.
set "RC=1"
set "TB=%SELWIN%:\Windows\System32\bcdboot.exe"
if exist "%TB%" (
    "%TB%" %SELWIN%:\Windows /s %BL%: /f %BCDFW% /l hu-HU >"%DPO%" 2>&1
    set "RC=!ERRORLEVEL!"
    call :LogDPO "bcdboot [cel-Windows] /f %BCDFW% /l hu-HU - rc=!RC!"
)
if "%RC%"=="0" goto BcdOk
if exist "%TB%" (
    "%TB%" %SELWIN%:\Windows /s %BL%: /f %BCDFW% >"%DPO%" 2>&1
    set "RC=!ERRORLEVEL!"
    call :LogDPO "bcdboot [cel-Windows] /f %BCDFW% - rc=!RC!"
)
if "%RC%"=="0" goto BcdOk
bcdboot %SELWIN%:\Windows /s %BL%: /f %BCDFW% /l hu-HU >"%DPO%" 2>&1
set "RC=%ERRORLEVEL%"
call :LogDPO "bcdboot [futo rendszer] /f %BCDFW% /l hu-HU - rc=%RC%"
if "%RC%"=="0" goto BcdOk
bcdboot %SELWIN%:\Windows /s %BL%: /f %BCDFW% >"%DPO%" 2>&1
set "RC=%ERRORLEVEL%"
call :LogDPO "bcdboot [futo rendszer] /f %BCDFW% - rc=%RC%"
if "%RC%"=="0" goto BcdOk
goto :eof
:BcdOk
echo   [OK] bcdboot sikeres.
goto :eof

:SingleBoot
rem Single boot: az uj BCD-ben csak a kivalasztott Windows van, a menu nem
rem varakozik. Az "osdevice" sorokat szamoljuk - a bcdedit mezonevei nem
rem lokalizaltak, az "identifier" felirat viszont igen.
bcdedit /store %1 /timeout 0 >"%DPO%" 2>&1
set "RC=%ERRORLEVEL%"
call :LogDPO "bcdedit timeout 0 - rc=%RC%"
set /a OSCNT=0
for /f "tokens=1" %%a in ('bcdedit /store %1 /enum osloader 2^>nul') do if /i "%%a"=="osdevice" set /a OSCNT+=1
>>"%LOG%" echo Windows-bejegyzesek az uj BCD-ben: %OSCNT%
if "%OSCNT%"=="1" (
    echo   [OK] Single boot: egy Windows-bejegyzes, varakozas nelkul.
) else (
    echo   [FIGYELEM] Az uj boot menuben %OSCNT% Windows-bejegyzes van - reszletek a logban.
    bcdedit /store %1 /enum osloader >>"%LOG%" 2>&1
)
goto :eof

:DoM2G
rem MBR lemez + UEFI: a Legacy boot mar a lemezen van, most a Microsoft
rem mbr2gpt-je alakitja GPT-re (EFI particio + UEFI boot fajlok, a
rem meghajtobetu-terkep frissitese). Elobb /validate - az csak olvas.
set "M2GFAIL="
set "M2GARGS=/disk:%SELNUM%"
if not defined ISPE set "M2GARGS=/disk:%SELNUM% /allowFullOS"
echo   [4/4] Atalakitas GPT-re - mbr2gpt ellenorzes, csak olvas...
call :M2GRun validate
if not "%RC%"=="0" (
    echo   [INFO] Az ellenorzes nem ment at - helyet csinalok az EFI particionak, es ujraprobalom.
    >"%DPS%" (
        echo select volume %SELWIN%
        echo shrink desired=316 minimum=316
    )
    call :DPRun
    if "!DPRC!"=="0" call :M2GRun validate
)
if not "%RC%"=="0" (
    echo   [HIBA] Az mbr2gpt szerint ez a lemez nem alakithato at. Uzenete:
    type "%DPO%"
    call :M2GErrLog
    set "M2GFAIL=1"
    goto :eof
)
echo   [OK] Atalakithato. Atalakitas - ez par percig tarthat...
call :M2GRun convert
set "GPTNOW="
>"%DPS%" (
    echo select disk %SELNUM%
    echo uniqueid disk
)
call :DPRun
findstr /r /c:"-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-" "%DPO%" >nul 2>&1 && set "GPTNOW=1"
if "%RC%"=="0" if defined GPTNOW (
    echo   [OK] A lemez most GPT, a UEFI boot kesz.
    set "BCDFW=UEFI"
    set "PSTYLE=GPT"
    goto :eof
)
echo   [HIBA] Az atalakitas nem sikerult - mbr2gpt kod: %RC%, GPT: %GPTNOW%. Reszletek a logban.
call :M2GErrLog
set "M2GFAIL=1"
goto :eof

:MakeBootPart
rem Uj boot particio ugy, hogy NE maradjon ures resz (explicit user decision):
rem  A) ha a lemez elejen MINSZ..1024 MB szabad hely van, a particio pontosan
rem     azt tolti ki (offset=1024 KB, meret nelkul = a kovetkezo particioig);
rem  B) kulonben a Windows mogott: a Windows elobb atveszi a mogotte levo
rem     szabad helyet, aztan pontosan SIZE MB-tal zsugorodik, es az uj particio
rem     ezt a helyet tolti ki.
rem MKFAIL = nem sikerult, MKHALF = letrejott, de formazas/betu nem.
set "MKFAIL="
set "MKHALF="
call :FreeLetter
if not defined BL (
    echo   [HIBA] Nincs szabad meghajtobetu a particiohoz.
    set "MKFAIL=1"
    goto :eof
)
>>"%LOG%" echo Ideiglenes betu az uj particiohoz: %BL%:
call :ListParts
set "PCB=%PCOUNT%"
set /a LEADMB=MINOFF-1
>>"%LOG%" echo Szabad hely a lemez elejen: %LEADMB% MB - minimum %MINSZ% MB, maximum 1024 MB a kitolteshez
if %LEADMB% GEQ %MINSZ% if %LEADMB% LEQ 1024 (
    echo   [INFO] A lemez elejen %LEADMB% MB szabad hely van - a boot particio azt tolti ki.
    set "CRSIZE="
    set "CROFF=1024"
    call :CreatePart
    if exist %BL%:\ (
        set "CHANGED=1"
        goto :eof
    )
    call :ListParts
    if not "!PCOUNT!"=="%PCB%" (
        set "MKHALF=1"
        goto :eof
    )
    echo   [INFO] Oda nem sikerult - a Windows moge teszem.
    >>"%LOG%" echo A lemez eleji kitoltes nem sikerult - B valtozat.
)
rem B) Windows moge, hezag nelkul
call :ExtendWin quiet
>"%DPS%" (
    echo select volume %SELWIN%
    echo shrink desired=%SIZE% minimum=%SIZE%
)
call :DPRun
if not "%DPRC%"=="0" (
    echo   [HIBA] A %SELWIN%: kotet zsugoritasa nem sikerult. Diskpart uzenete:
    type "%DPO%"
    echo.
    echo   Tipp: BitLockeres kotetnel kapcsold ki a BitLockert, kulonben futtass
    echo   chkdsk %SELWIN%: /f parancsot, es probald ujra.
    set "MKFAIL=1"
    goto :eof
)
set "CHANGED=1"
set "CRSIZE=%SIZE%"
set "CROFF="
call :CreatePart
if exist %BL%:\ goto :eof
call :ListParts
if not "%PCOUNT%"=="%PCB%" (
    set "MKHALF=1"
    goto :eof
)
echo   [HIBA] Az uj particio letrehozasa nem sikerult. Diskpart uzenete:
type "%DPO%"
echo.
echo   A Windows mogott %SIZE% MB szabad hely maradt - ha ujrafuttatod a scriptet, az kitolti.
if "%SELGPT%"=="0" echo   MBR lemezen legfeljebb 4 primary particio lehet - lehet, hogy mar nincs tobb hely.
set "MKFAIL=1"
goto :eof

:ExtendWin
rem A Windows kotet atveszi a KOZVETLENUL mogotte levo szabad helyet.
rem Ha nincs ilyen, a diskpart hibat ad - az nem hiba, csak naplozzuk.
rem %1 = quiet: nem ir ki semmit (a boot particio elokeszitesekor).
>"%DPS%" (
    echo select volume %SELWIN%
    echo extend
)
call :DPRun
if "%DPRC%"=="0" (
    if /i not "%~1"=="quiet" echo   [OK] A Windows kotet atvette a mogotte levo szabad helyet.
) else (
    >>"%LOG%" echo extend: a Windows mogott nincs kozvetlen szabad hely - nincs mit hozzaadni.
)
goto :eof

:DiskFree
rem Maradt-e nem lefoglalt terulet a lemezen (list disk "Free" oszlop).
set "DFREE="
>"%DPS%" echo list disk
call :DPRun
for /f "usebackq tokens=1-7" %%a in ("%DPO%") do if "%%b"=="%SELNUM%" call :DiskFreeLine "%%a" "%%f" "%%g"
if not defined DFREE goto :eof
echo   [INFO] Maradt %DFREE% nem lefoglalt terulet a lemezen. Ez nem a Windows mogott
echo          van, ezert a Windows nem tudja atvenni - ahhoz a Windows particiot el
echo          kellene tolni, amit ez a script nem csinal. A bootot nem zavarja.
goto :eof

:DiskFreeLine
set "F1=%~1"
if /i not "!F1!"=="Disk" if /i not "!F1!"=="Lemez" goto :eof
set "FV=%~2"
set "FU=%~3"
if "!FV!"=="0" goto :eof
if /i "!FU!"=="KB" goto :eof
if /i "!FU!"=="MB" if !FV! LSS 2 goto :eof
set "DFREE=!FV! !FU!"
goto :eof

:M2GRun
"%M2G%" /%1 %M2GARGS% >"%DPO%" 2>&1
set "RC=%ERRORLEVEL%"
call :LogDPO "mbr2gpt /%1 %M2GARGS% - rc=%RC%"
goto :eof

:M2GErrLog
rem Az mbr2gpt sajat hibanaploja a Windows mappaban van.
>>"%LOG%" echo.
>>"%LOG%" echo ===== mbr2gpt setuperr.log =====
type "%SystemRoot%\setuperr.log" >>"%LOG%" 2>nul
goto :eof

:Sleep
ping -n %1 127.0.0.1 >nul 2>&1
goto :eof
