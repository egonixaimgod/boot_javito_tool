@echo off
setlocal EnableExtensions EnableDelayedExpansion
title BootFixer
rem =====================================================
rem   BOOTFIXER v5 - UJ boot particio letrehozasa
rem
rem   1. lemez kivalasztasa (azon a lemezen kell lennie a Windowsnak)
rem   2. boot mod: UEFI vagy Legacy BIOS / MBR
rem   3. a particios tablat NEM alakitja at (2026-09-23 ota KIKAPCSOLVA,
rem      mert az elso eles futas tonkretett egy lemezt): UEFI + MBR lemez
rem      eseten FAT32 boot particio ESP tipussal, Legacy + GPT lemez
rem      eseten elutasitja. A beagyazott PowerShell resz a fajl vegen
rem      marad, de a :ConvPlan nem engedi lefutni.
rem   4. UJ boot particio a lemezen (a Windows kotet zsugoritasabol,
rem      ha nincs szabad hely)
rem   5. boot fajlok irasa az uj particiora (bcdboot)
rem
rem   WinPE (pl. Sergei Strelec) es teljes Windows alatt is fut. A tabla
rem   atalakitasahoz PowerShell kell (a fajl vegere agyazott resz), es a
rem   futo Windows sajat lemezet nem lehet atalakitani - azt WinPE-bol.
rem   Minden diskpart/bcdboot/bootsect/PowerShell lepes a logba kerul.
rem
rem   FIGYELEM a szerkesztesnel: a script delayed expansion-nel fut, ezert
rem   a kiirt szovegekben NEM lehet felkialtojel, es a "->" jel sem, mert
rem   a ">" atiranyitas.
rem =====================================================

set "BF_SELF=%~f0"

rem --- Temp konyvtar ---
set "TMPD=%TEMP%"
if not exist "%TMPD%" set "TMPD=X:\Windows\Temp"
if not exist "%TMPD%" set "TMPD=%SystemRoot%\Temp"
if not exist "%TMPD%" set "TMPD=%~dp0"
set "DPS=%TMPD%\bf_dp.txt"
set "DPO=%TMPD%\bf_out.txt"
set "DRV=%TMPD%\bf_drv.txt"
set "PS1=%TMPD%\bf_conv.ps1"
set "CVO=%TMPD%\bf_conv_out.txt"

rem --- Log fajl: eloszor a script mappaja (USB stick - ujrainditas utan is
rem     megmarad), ha az nem irhato, akkor a temp konyvtar ---
set "LOG=%~dp0bootfixer_log.txt"
(type nul >>"%LOG%") 2>nul || set "LOG=%TMPD%\bootfixer_log.txt"
>"%LOG%" echo ===== BootFixer v5 log - %DATE% %TIME% =====

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
rem WinPE: PEFirmwareType (1=BIOS, 2=UEFI), a wpeutil tolti ki.
rem Teljes Windows: a futo rendszer betoltoje winload.efi vagy winload.exe.
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
echo        v5 - uj boot particio
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
set /p "CH=  Melyik lemezre kerul az uj boot particio? [szam]: "
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
rem van mukodo bootja, es az o boot-beallitasait irnank at futas kozben.
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
set "CONVERT="
set "CV_DROP="
echo.
echo   Milyen boot legyen?
echo     [1] UEFI
echo     [2] Legacy BIOS / MBR
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
set "BCDFW=UEFI"
set "FS=fat32"
set "SIZE=300"
set "ACTIVE="
set "SETID="
set /a SHR=SIZE+16
set "MODE=UEFI"
set "PTYPE=efi"
rem UEFI teljes Windowsbol is fut (explicit user decision, 2026-09-23 - a v4
rem WinPE-zara visszavonva). A bcdboot ilyenkor a futo gep firmware boot-
rem bejegyzeset is atirhatja - ezt a :DONE vegen figyelmeztetes mondja ki.
if "%SELGPT%"=="1" goto CONFIRM
rem MBR lemez + UEFI: eloszor GPT-re alakitas (ez a tiszta megoldas).
echo.
echo   Ez MBR lemez - UEFI-hez GPT a helyes. Ellenorzom, atalakithato-e...
call :ConvPlan GPT
if "!CV_STATUS!"=="OK" (
    set "CONVERT=GPT"
    set "MODE=UEFI - a lemez GPT-re alakitasaval"
    echo   [OK] Atalakithato - a Windows particio adatai megmaradnak.
    goto CONFIRM
)
rem Nem alakithato at: marad MBR, FAT32 boot particio ESP tipussal (0xEF).
rem A UEFI firmware MBR lemezrol is indit, ha talal rajta FAT particiot
rem \EFI\BOOT\BOOTX64.EFI-vel - ezt a bcdboot /f UEFI letrehozza.
echo   [INFO] GPT-re nem alakithato: !CV_MSG!
echo          Marad MBR, a boot particio FAT32 lesz ESP tipussal - a legtobb UEFI gep ezt is inditja.
set "MODE=UEFI - MBR lemezen"
set "PTYPE=primary"
set "SETID=ef"
goto CONFIRM

:MODELEG
set "MODE=Legacy BIOS / MBR"
set "BCDFW=BIOS"
set "PTYPE=primary"
set "FS=ntfs"
set "SIZE=500"
set "ACTIVE=1"
set "SETID="
set /a SHR=SIZE+16
if "%SELGPT%"=="0" goto CONFIRM
rem GPT lemez + Legacy: Legacy BIOS-bol GPT lemezrol a Windows nem indul,
rem tehat a tablat MBR-re kell alakitani.
echo.
echo   Ez GPT lemez - Legacy boothoz MBR kell. Ellenorzom, atalakithato-e...
call :ConvPlan MBR
if not "!CV_STATUS!"=="OK" (
    echo   [HIBA] MBR-re nem alakithato: !CV_MSG!
    echo          Ezt a lemezt igy csak UEFI boottal lehet inditani.
    goto ASKMODE
)
set "CONVERT=MBR"
set "MODE=Legacy BIOS / MBR - a lemez MBR-re alakitasaval"
echo   [OK] Atalakithato - a Windows particio adatai megmaradnak.
goto CONFIRM

rem =====================================================
rem   MEGEROSITES
rem =====================================================
:CONFIRM
echo.
echo   ===================================================
echo     Lemez:     !SELMOD! ^| !SELSIZE! ^| %PSTYLE%
echo     Windows:   %SELWIN%:\Windows
echo     Boot mod:  %MODE%
echo   ===================================================
echo   Ezt fogom csinalni:
if defined CONVERT (
    echo     0. A particios tabla atalakitasa %PSTYLE%-rol %CONVERT%-re. A Windows particio
    echo        bajtra ugyanott marad, a fajljaihoz nem nyulok, es a Windows
    echo        meghajtobetu-terkepet az uj azonositora frissitem.
    if defined CV_DROP echo        Torlodik: !CV_DROP! - ezeken nincs adat, a boot ugyis ujra lesz irva.
)
echo     1. Uj %SIZE% MB-os boot particio ezen a lemezen, %FS% fajlrendszerrel.
echo        Ha nincs eleg szabad hely, a %SELWIN%: kotetet zsugoritom %SHR% MB-tal.
echo     2. Boot fajlok irasa az uj particiora a %SELWIN%:\Windows-bol.
if defined ACTIVE echo     3. Az uj particio lesz az aktiv, es uj MBR boot kod kerul a lemezre.
if not defined CONVERT echo   A regi boot particiokhoz es a Windows adataihoz nem nyulok.
if defined CONVERT (
    echo.
    echo   A tabla atalakitasa a legkockazatosabb lepes: ha a lemezen fontos adat
    echo   van, legyen rola mentes. BitLockeres gepnel az elso indulaskor a
    echo   helyreallito kulcsot kerheti.
)
echo.
set "CONF="
set /p "CONF=  Folytatod? (i/n): "
if /i not "!CONF!"=="i" (
    echo   Megszakitva.
    goto END
)
>>"%LOG%" echo.
>>"%LOG%" echo ===== VALASZTAS: lemez=%SELNUM% [!SELMOD!] %PSTYLE%, Windows=%SELWIN%:, mod=%MODE%, atalakitas=%CONVERT%, particio=%PTYPE% %SIZE% MB %FS% =====
set "CHANGED="

rem =====================================================
rem   0. PARTICIOS TABLA ATALAKITASA (ha kell)
rem =====================================================
if defined CONVERT (
    echo.
    echo   [0/3] Particios tabla atalakitasa %CONVERT%-re...
    call :ConvRun
    if defined CV_CHANGED set "CHANGED=1"
    if not "!CV_STATUS!"=="OK" (
        echo.
        echo   [HIBA] Az atalakitas nem sikerult: !CV_MSG!
        goto FAIL
    )
    echo   [OK] A lemez most %CONVERT%.
    if not "!CV_REG!"=="1" (
        echo   [FIGYELEM] A Windows meghajtobetu-terkepet nem sikerult frissiteni.
        echo              Ha a Windows nem indul vagy nem C: lesz, ez az oka - reszletek a logban.
    )
    if "%CONVERT%"=="GPT" (set "SELGPT=1") else (set "SELGPT=0")
    set "PSTYLE=%CONVERT%"
)

rem =====================================================
rem   3. UJ BOOT PARTICIO
rem =====================================================
echo.
echo   [1/3] Uj boot particio letrehozasa...
call :FreeLetter
if not defined BL (
    echo   [HIBA] Nincs szabad meghajtobetu a particiohoz.
    goto FAIL
)
>>"%LOG%" echo Ideiglenes betu az uj particiohoz: %BL%:

call :ListParts
set "PCB=%PCOUNT%"
call :CreatePart
if exist %BL%:\ goto PARTOK
call :ListParts
if not "%PCOUNT%"=="%PCB%" goto PARTHALF

rem Nem jott letre semmi -> nincs eleg szabad hely. Zsugoritas, majd ujra.
echo   [INFO] Nincs eleg szabad hely a lemezen - a %SELWIN%: kotet zsugoritasa %SHR% MB-tal...
>"%DPS%" (
    echo select volume %SELWIN%
    echo shrink desired=%SHR% minimum=%SHR%
)
call :DPRun
if not "%DPRC%"=="0" (
    echo   [HIBA] A %SELWIN%: kotet zsugoritasa nem sikerult. Diskpart uzenete:
    type "%DPO%"
    echo.
    echo   Tipp: BitLockeres kotetnel kapcsold ki a BitLockert, kulonben futtass
    echo   chkdsk %SELWIN%: /f parancsot, es probald ujra.
    goto FAIL
)
set "CHANGED=1"
echo   [OK] Zsugoritva.
call :CreatePart
if exist %BL%:\ goto PARTOK
call :ListParts
if not "%PCOUNT%"=="%PCB%" goto PARTHALF
echo   [HIBA] Az uj particio letrehozasa nem sikerult. Diskpart uzenete:
type "%DPO%"
echo.
echo   A zsugoritas utan kb. %SHR% MB szabad hely maradt a lemezen - ez artalmatlan.
if "%SELGPT%"=="0" echo   MBR lemezen legfeljebb 4 primary particio lehet - lehet, hogy mar nincs tobb hely.
goto FAIL

:PARTHALF
set "CHANGED=1"
echo   [HIBA] A particio letrejott, de a formazas vagy a betujel kiosztasa nem sikerult.
echo   Diskpart uzenete:
type "%DPO%"
echo.
echo   A felig kesz particiot diskpart-tal torolheted: select disk %SELNUM%, list partition,
echo   select partition N, delete partition override - utana futtasd ujra ezt a scriptet.
goto FAIL

:PARTOK
set "CHANGED=1"
if defined NEWPART (
    echo   [OK] Uj boot particio kesz: %BL%: - lemez %SELNUM%, particio %NEWPART%
) else (
    echo   [OK] Uj boot particio kesz: %BL%:
)

rem =====================================================
rem   4. BOOT FAJLOK
rem =====================================================
echo   [2/3] Boot fajlok irasa...
set "BOOTERR="
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

rem =====================================================
rem   5. LEZARAS: betujel levetele (+ ESP tipus MBR lemezen)
rem =====================================================
echo   [3/3] Particio lezarasa...
>"%DPS%" (
    echo select disk %SELNUM%
    if defined NEWPART (echo select partition %NEWPART%) else (echo select volume %BL%)
    echo remove letter=%BL%
)
call :DPRun
if defined SETID (
    if defined NEWPART (
        >"%DPS%" (
            echo select disk %SELNUM%
            echo select partition %NEWPART%
            echo set id=%SETID% override
        )
        call :DPRun
        if "!DPRC!"=="0" (
            echo   [OK] ESP tipus beallitva.
        ) else (
            echo   [FIGYELEM] Az ESP tipus beallitasa nem sikerult - a legtobb gep igy is indit.
        )
    ) else (
        echo   [FIGYELEM] Az uj particio szama nem derult ki - ESP tipus kihagyva.
    )
)
echo   [OK] Kesz.
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
echo   ===================================================
echo     KESZ: uj %MODE% boot particio a %SELNUM%. lemezen.
echo   ===================================================
echo.
echo   Mielott ujrainditasz, a gep BIOS-aban:
if "%BCDFW%"=="UEFI" (
    echo     - a boot mod legyen UEFI, CSM/Legacy KI
    echo     - a boot sorrendben a Windows Boot Manager legyen elol
) else (
    echo     - a boot mod legyen Legacy/CSM
    echo     - ez a lemez legyen az elso a boot sorrendben
)
echo     - a SATA mod maradjon azon, amin a Windows telepult - altalaban AHCI.
echo       Ha RAID-re vagy IDE-re allitod, a Windows INACCESSIBLE_BOOT_DEVICE hibaval all le.
if "%BCDFW%"=="UEFI" if "%FWMODE%"=="Legacy BIOS" echo   [FIGYELEM] Ez a gep most Legacy modban fut - a BIOS-ban at kell allitani UEFI-re.
if "%BCDFW%"=="BIOS" if "%FWMODE%"=="UEFI" echo   [FIGYELEM] Ez a gep most UEFI modban fut - a BIOS-ban be kell kapcsolni a CSM/Legacy modot.
if "%BCDFW%"=="UEFI" if not defined ISPE (
    echo.
    echo   [INFO] A bcdboot UEFI modban ennek a gepnek - amin most futtattad - a boot
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
del "%PS1%" >nul 2>&1
del "%CVO%" >nul 2>&1
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
rem ISNUM=1, ha a %1 nevu valtozo csak szamjegyekbol all (pipe es findstr
rem nelkul, igy a felhasznalo altal begepelt furcsa karakterek sem torik el).
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
set "DWIN_%DCOUNT%="
set "DWCNT_%DCOUNT%=0"
goto :eof

:GetModel
rem Lemez modellnev (wmic - opcionalis, uj Windowson hianyozhat).
set "N=!DNUM_%1!"
for /f "tokens=1* delims==" %%a in ('wmic diskdrive where "Index=%N%" get Model /value 2^>nul ^| find "="') do (
    for /f "delims=" %%c in ("%%b") do if not "%%c"=="" set "DMOD_%1=%%c"
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
rem PCOUNT = particiok szama a kivalasztott lemezen (lokalizacio-fuggetlen:
rem "Partition N" es "Particio N" is "Part"-tal kezdodik).
>"%DPS%" (
    echo select disk %SELNUM%
    echo list partition
)
call :DPRun
set /a PCOUNT=0
for /f "usebackq tokens=1-3" %%a in ("%DPO%") do call :CountLine "%%a" "%%b" "%%c"
>>"%LOG%" echo Particiok szama a %SELNUM%. lemezen: %PCOUNT%
goto :eof

:CountLine
set "C1=%~1"
set "C2=%~2"
if "!C1!"=="*" (
    set "C1=%~2"
    set "C2=%~3"
)
if /i not "!C1:~0,4!"=="Part" goto :eof
call :IsNum C2
if defined ISNUM set /a PCOUNT+=1
goto :eof

:CreatePart
rem Microsoft sajat WinPE mintaszkriptjeinek sorrendje:
rem create -> format -> assign [-> active]. A vegen a "list partition"
rem csillaggal jeloli a fokuszban levot = az imen letrehozott particiot.
rem Ha a create elbukik, a diskpart ott megall, es semmi nem valtozik.
set "NEWPART="
>"%DPS%" (
    echo select disk %SELNUM%
    echo create partition %PTYPE% size=%SIZE%
    echo format quick fs=%FS% label=SYSTEM
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
rem WinPE-ben / telepito media-n van; teljes Windowson hianyozhat - ott a
rem formazas mar Windows boot szektort irt, es a regi MBR kod is az aktiv
rem particiot inditja. Tablaatalakitas utan viszont a "clean" nullazta az
rem MBR-t, ott a bootsect nelkul a lemez nem indulna - ezt kiirjuk.
where bootsect >nul 2>&1
if errorlevel 1 (
    if defined CONVERT (
        echo   [HIBA] bootsect nem elerheto, az uj MBR-ben pedig nincs boot kod.
        echo          Futtasd ezt WinPE-bol, vagy utana: bootrec /fixmbr
        set "BOOTERR=1"
    ) else (
        echo   [FIGYELEM] bootsect nem elerheto - az MBR boot kod nem lett ujrairva.
        echo              Ha a gep Legacy modban nem indul errol a lemezrol, futtasd ujra
        echo              ezt a scriptet WinPE-bol - ott van bootsect, es azt is megirja.
    )
    >>"%LOG%" echo bootsect nem elerheto - kihagyva
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
    if defined CONVERT set "BOOTERR=1"
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
rem Single boot: az uj BCD-ben csak a kivalasztott Windows van (a bcdboot
rem uj, ures store-t hoz letre az uj particion), a menu nem varakozik.
rem Az "osdevice" sorokat szamoljuk - a bcdedit mezonevei nem lokalizaltak,
rem az "identifier" felirat viszont igen, ezert arra nem epitunk.
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

:ExtractPS
rem A fajl vegere agyazott PowerShell reszt kiirja a %PS1%-be.
rem PSOK=1, ha sikerult ES a Storage modul (Get-Partition) elerheto.
set "PSOK="
set "BF_PS1=%PS1%"
where powershell >nul 2>&1 || goto :eof
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:BF_SELF); $m='##'+'PSCONV##'; $i=$t.LastIndexOf($m); if($i -lt 0){exit 2}; [IO.File]::WriteAllText($env:BF_PS1, $t.Substring($i+$m.Length).TrimStart()); if(Get-Command Get-Partition -ErrorAction SilentlyContinue){exit 0}else{exit 3}" >nul 2>&1
if errorlevel 1 goto :eof
set "PSOK=1"
goto :eof

:ConvPlan
rem Csak ELLENORZES (semmit nem ir): atalakithato-e a lemez %1 tablara.
set "CV_STATUS=" & set "CV_MSG=" & set "CV_DROP=" & set "CV_CHANGED=" & set "CV_REG="
rem KIKAPCSOLVA (2026-09-23): az elso eles futas egy lemez particios tablajat
rem tonkretette. Amig VHD-n vegig nem ment, a tablat NEM alakitjuk at.
set "CV_STATUS=ERR"
set "CV_MSG=a particios tabla atalakitasa ebben a verzioban ki van kapcsolva"
goto :eof
if not defined ISPE if /i "%SELWIN%"=="%SystemDrive:~0,1%" (
    set "CV_STATUS=ERR"
    set "CV_MSG=ez a most futo Windows lemeze - az atalakitashoz inditsd a gepet WinPE-rol"
    goto :eof
)
call :ExtractPS
if not defined PSOK (
    set "CV_STATUS=ERR"
    set "CV_MSG=ebben a kornyezetben nincs PowerShell Storage modul - az atalakitashoz az kell"
    goto :eof
)
call :ConvCall plan %1
goto :eof

:ConvRun
rem A tenyleges atalakitas (a :ConvPlan mar kiirta a %PS1%-t).
set "CV_STATUS=" & set "CV_MSG=" & set "CV_DROP=" & set "CV_CHANGED=" & set "CV_REG="
if not exist "%PS1%" call :ExtractPS
call :ConvCall run %CONVERT%
goto :eof

:ConvCall
rem %1 = plan/run, %2 = GPT/MBR. Eredmeny: CV_STATUS, CV_MSG, CV_DROP, CV_CHANGED, CV_REG.
del "%CVO%" >nul 2>&1
>>"%LOG%" echo.
>>"%LOG%" echo ===== tabla-atalakitas: %1 %2 - lemez %SELNUM%, Windows %SELWIN%:, zsugoritas %SHR% MB =====
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Disk %SELNUM% -Target %2 -Win %SELWIN% -ShrinkMB %SHR% -Mode %1 -Log "%LOG%" -Out "%CVO%" 2>"%TMPD%\bf_ps_err.txt"
type "%TMPD%\bf_ps_err.txt" >>"%LOG%" 2>nul
del "%TMPD%\bf_ps_err.txt" >nul 2>&1
if not exist "%CVO%" (
    set "CV_STATUS=ERR"
    set "CV_MSG=a PowerShell resz hibaval leallt - reszletek a logban"
    goto :eof
)
for /f "usebackq tokens=1* delims==" %%a in ("%CVO%") do set "CV_%%a=%%b"
if not defined CV_STATUS (
    set "CV_STATUS=ERR"
    set "CV_MSG=a PowerShell resz nem adott eredmenyt"
)
goto :eof

:Sleep
ping -n %1 127.0.0.1 >nul 2>&1
goto :eof

rem =====================================================
rem   Az alabbi resz PowerShell - a batch sosem jut el ide,
rem   a :ExtractPS irja ki a marker utani szoveget .ps1-be.
rem =====================================================
##PSCONV##
param(
    [int]$Disk,
    [string]$Target,
    [string]$Win,
    [int]$ShrinkMB,
    [string]$Mode,
    [string]$Log,
    [string]$Out
)
# BootFixer - particios tabla atalakitasa (GPT <-> MBR) ADATVESZTES NELKUL.
#
# A modszer: a Windows particiot eloszor zsugoritjuk (igy a vegen szabad hely
# lesz a boot particionak, es a Windows nem er bele a lemez utolso MB-jaba),
# megjegyezzuk a PONTOS kezdetet es meretet bajtban, a diskpart "clean"-nel
# csak a particios tablat toroljuk (a lemez elso es utolso 1 MB-jat irja, a
# particiot nem), atalakitjuk, majd a particiot bajtra ugyanoda hozzuk letre.
# A fajlrendszerhez egyetlen bajtot sem irunk. Vegul a Windows sajat
# MountedDevices bejegyzeset az uj azonositora allitjuk, kulonben a Windows
# nem kapna C: betut es nem indulna el.
#
# Plan mod: csak ellenoriz, semmit nem ir. Run mod: vegrehajt.
# Eredmeny a -Out fajlba: STATUS=OK|ERR|NOOP, MSG=..., DROP=..., CHANGED=1, REG=1

$ErrorActionPreference = 'Continue'
$MSR   = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
$ESP   = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$BASIC = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$MB    = [int64]1048576
$Win   = $Win.Substring(0, 1).ToUpper()
$Target = $Target.ToUpper()
$script:Changed = $false

function Log-Line([string]$m) {
    try { Add-Content -LiteralPath $Log -Value ('[PS] ' + $m) -Encoding ASCII } catch { }
}
function Say([string]$m) {
    Write-Host ('  ' + $m)
    Log-Line $m
}
function Safe([string]$s) {
    if ($null -eq $s) { return '' }
    return (($s -replace '[^\x20-\x7E]', '?') -replace '[&|<>^!%"]', ' ')
}
function Finish([string]$status, [string]$msg, [hashtable]$extra) {
    $lines = @(('STATUS=' + $status), ('MSG=' + (Safe $msg)))
    if ($script:Changed) { $lines += 'CHANGED=1' }
    if ($extra) { foreach ($k in $extra.Keys) { $lines += ($k + '=' + (Safe ([string]$extra[$k]))) } }
    Set-Content -LiteralPath $Out -Value $lines -Encoding ASCII
    Log-Line ('EREDMENY: ' + ($lines -join ' | '))
    exit 0
}
function MbOf([int64]$b) { return [int64][math]::Round($b / $MB) }
function Hex([byte[]]$b) {
    if ($null -eq $b) { return '(nincs)' }
    return (($b | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Run-Diskpart([string[]]$cmds) {
    $f = Join-Path (Split-Path -Parent $Out) 'bf_conv_dp.txt'
    Set-Content -LiteralPath $f -Value $cmds -Encoding ASCII
    $o = (& diskpart.exe /s $f | Out-String)
    $rc = $LASTEXITCODE
    Log-Line ('diskpart [' + ($cmds -join ' / ') + '] kilepesi kod=' + $rc)
    Log-Line $o
    Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue
    return $rc
}

function Analyze {
    $r = @{ Err = $null; Disk = $null; Style = ''; Win = $null; Drop = @() }
    try { $d = Get-Disk -Number $Disk -ErrorAction Stop }
    catch { $r.Err = 'a lemez nem olvashato: ' + $_.Exception.Message; return $r }
    $r.Disk = $d
    $r.Style = [string]$d.PartitionStyle
    if ($r.Style -ne 'GPT' -and $r.Style -ne 'MBR') { $r.Err = 'a lemez tablaja ismeretlen (' + $r.Style + ')'; return $r }
    try { $parts = @(Get-Partition -DiskNumber $Disk -ErrorAction Stop) }
    catch { $r.Err = 'a particiok nem olvashatok: ' + $_.Exception.Message; return $r }
    $wp = $parts | Where-Object { ([string]$_.DriveLetter) -eq $Win } | Select-Object -First 1
    if (-not $wp) { $r.Err = 'a ' + $Win + ': meghajto nem ezen a lemezen van'; return $r }
    $r.Win = $wp
    $block = @()
    foreach ($p in $parts) {
        if ($p.PartitionNumber -eq $wp.PartitionNumber) { continue }
        $desc = 'particio ' + $p.PartitionNumber + ' (' + (MbOf $p.Size) + ' MB'
        if (([string]$p.GptType) -eq $MSR) { $r.Drop += ($desc + ', MSR)') }
        elseif ((([string]$p.GptType) -eq $ESP) -or ($p.MbrType -eq 239)) { $r.Drop += ($desc + ', regi EFI boot)') }
        else {
            $lt = ''
            if ([string]$p.DriveLetter -match '[A-Z]') { $lt = ', ' + $p.DriveLetter + ':' }
            $block += ($desc + $lt + ')')
        }
    }
    if ($block.Count -gt 0) {
        $r.Err = 'a lemezen mas particio is van: ' + ($block -join ', ') + ' - az atalakitas ezeket torolne, ezert nem csinalom'
        return $r
    }
    if ([int64]$wp.Offset -lt $MB) {
        $r.Err = 'a Windows particio a lemez elso 1 MB-jan belul kezdodik - igy nem alakithato at biztonsagosan'
        return $r
    }
    if ($Target -eq 'MBR') {
        $lim = [int64]$d.LogicalSectorSize * [int64]4294967296
        if (([int64]$wp.Offset + [int64]$wp.Size) -gt $lim) {
            $r.Err = 'a Windows particio tulnyulik az MBR hataran (512 bajtos szektornal 2 TB) - MBR-re nem alakithato'
            return $r
        }
    }
    try { $sup = Get-PartitionSupportedSize -DiskNumber $Disk -PartitionNumber $wp.PartitionNumber -ErrorAction Stop }
    catch { $r.Err = 'a zsugorithatosag nem kerdezheto le: ' + $_.Exception.Message; return $r }
    $want = [int64]$wp.Size - [int64]$ShrinkMB * $MB
    if ($want -lt [int64]$sup.SizeMin) {
        $r.Err = 'a ' + $Win + ': kotet nem zsugorithato ' + $ShrinkMB + ' MB-tal (keves a szabad hely rajta)'
        return $r
    }
    return $r
}

function Read-SysLetter {
    # A Windows SAJAT rendszerbetuje (a SOFTWARE hive SystemRoot erteke),
    # nem az, amit a WinPE adott neki.
    $letter = 'C'
    & reg.exe load 'HKLM\BF_SOFT' ($Win + ':\Windows\System32\config\SOFTWARE') | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Say 'FIGYELEM: a Windows SOFTWARE hive nem toltheto be - feltetelezett rendszerbetu: C'
        return $letter
    }
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('BF_SOFT\Microsoft\Windows NT\CurrentVersion')
        if ($k) {
            $sr = [string]$k.GetValue('SystemRoot')
            $k.Close()
            Log-Line ('SystemRoot = ' + $sr)
            if ($sr -match '^([A-Za-z]):') { $letter = $Matches[1].ToUpper() }
        }
    } catch { Log-Line ('SystemRoot olvasasi hiba: ' + $_.Exception.Message) }
    finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload 'HKLM\BF_SOFT' | Out-Null
    }
    Say ('A Windows sajat rendszerbetuje: ' + $letter + ':')
    return $letter
}

function Fix-Registry([string]$style, $part, [string]$sysLetter) {
    # MountedDevices: \DosDevices\C: = a kotet azonositoja.
    #   MBR: 4 bajt lemez-alairas + 8 bajt kezdo offset (little-endian)
    #   GPT: "DMIO:ID:" + a particio GUID-ja (16 bajt)
    try {
        if ($style -eq 'MBR') {
            $sig = [uint32](Get-Disk -Number $Disk).Signature
            if ($sig -eq 0) {
                $sig = [uint32](Get-Random -Minimum 268435456 -Maximum 2147483647)
                Run-Diskpart @(('select disk ' + $Disk), ('uniqueid disk id=' + $sig.ToString('X8'))) | Out-Null
                Update-HostStorageCache -ErrorAction SilentlyContinue
                $sig = [uint32](Get-Disk -Number $Disk).Signature
            }
            $bytes = [byte[]]([BitConverter]::GetBytes($sig) + [BitConverter]::GetBytes([uint64]$part.Offset))
        } else {
            $bytes = [byte[]]([Text.Encoding]::ASCII.GetBytes('DMIO:ID:') + ([guid]([string]$part.Guid)).ToByteArray())
        }
    } catch {
        Say ('FIGYELEM: az uj kotet-azonosito nem allapithato meg: ' + $_.Exception.Message)
        return $false
    }
    & reg.exe load 'HKLM\BF_SYS' ($Win + ':\Windows\System32\config\SYSTEM') | Out-Null
    if ($LASTEXITCODE -ne 0) { Say 'FIGYELEM: a Windows SYSTEM hive nem toltheto be'; return $false }
    $ok = $false
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('BF_SYS\MountedDevices')
        $name = '\DosDevices\' + $sysLetter + ':'
        Log-Line ('MountedDevices ' + $name + ' regi ertek: ' + (Hex ([byte[]]$k.GetValue($name))))
        $k.SetValue($name, $bytes, [Microsoft.Win32.RegistryValueKind]::Binary)
        Log-Line ('MountedDevices ' + $name + ' uj ertek:  ' + (Hex $bytes))
        $k.Close()
        $ok = $true
        Say ('A Windows ' + $sysLetter + ': betuje az uj particiohoz rendelve.')
    } catch { Say ('FIGYELEM: a MountedDevices irasa nem sikerult: ' + $_.Exception.Message) }
    finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Seconds 1
        & reg.exe unload 'HKLM\BF_SYS' | Out-Null
        if ($LASTEXITCODE -ne 0) { Start-Sleep -Seconds 3; & reg.exe unload 'HKLM\BF_SYS' | Out-Null }
    }
    return $ok
}

function Wait-Win {
    for ($i = 0; $i -lt 15; $i++) {
        if (Test-Path -LiteralPath ($Win + ':\Windows\System32')) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Make-WinPart([string]$style, $gptType) {
    # A friss tablan esetleg automatikusan letrejott particiok (pl. MSR) torlese,
    # majd a Windows particio letrehozasa PONTOSAN a regi kezdettel.
    Update-HostStorageCache -ErrorAction SilentlyContinue
    foreach ($p in @(Get-Partition -DiskNumber $Disk -ErrorAction SilentlyContinue)) {
        Say ('Automatikusan letrejott particio torlese: ' + $p.PartitionNumber + ' (' + (MbOf $p.Size) + ' MB)')
        Remove-Partition -DiskNumber $Disk -PartitionNumber $p.PartitionNumber -Confirm:$false -ErrorAction Stop
    }
    # Felfele kerekitett meret: a particio lehet nagyobb a fajlrendszernel, kisebb soha.
    $sz = [int64][math]::Ceiling($fsSize / $MB) * $MB
    if ($style -eq 'GPT') {
        $np = New-Partition -DiskNumber $Disk -Offset $off -Size $sz -GptType $gptType -ErrorAction Stop
    } else {
        $np = New-Partition -DiskNumber $Disk -Offset $off -Size $sz -MbrType IFS -ErrorAction Stop
    }
    Log-Line ('Uj particio: szam=' + $np.PartitionNumber + ' kezdet=' + $np.Offset + ' meret=' + $np.Size + ' (kert kezdet=' + $off + ', kert meret=' + $sz + ')')
    if ([int64]$np.Offset -ne $off -or [int64]$np.Size -lt $fsSize) {
        Remove-Partition -DiskNumber $Disk -PartitionNumber $np.PartitionNumber -Confirm:$false -ErrorAction SilentlyContinue
        throw ('a particio nem a pontos helyre kerult (kert kezdet ' + $off + ', kapott ' + $np.Offset + ')')
    }
    try { Set-Partition -DiskNumber $Disk -PartitionNumber $np.PartitionNumber -NewDriveLetter $Win -ErrorAction Stop }
    catch { Log-Line ('Betujel-hiba: ' + $_.Exception.Message) }
    return (Get-Partition -DiskNumber $Disk -PartitionNumber $np.PartitionNumber)
}

function Restore([string]$why) {
    Say ('HIBA: ' + $why)
    Update-HostStorageCache -ErrorAction SilentlyContinue
    $st = [string](Get-Disk -Number $Disk).PartitionStyle
    $cur = @(Get-Partition -DiskNumber $Disk -ErrorAction SilentlyContinue | Where-Object { [int64]$_.Offset -eq $off })
    if ($st -eq $orig -and $cur.Count -gt 0) {
        Say 'Az eredeti tabla ep maradt - nincs mit visszaallitani.'
        return $true
    }
    Say ('VISSZAALLITAS: az eredeti ' + $orig + ' tabla es a Windows particio visszairasa...')
    Run-Diskpart @(('select disk ' + $Disk), 'clean', ('convert ' + $orig.ToLower())) | Out-Null
    try {
        $gt = $origGpt
        if (-not $gt) { $gt = $BASIC }
        $rp = Make-WinPart $orig $gt
        if (Wait-Win) {
            Say 'Visszaallitva - a Windows particio ujra olvashato.'
            Fix-Registry $orig $rp $sysLetter | Out-Null
            return $true
        }
    } catch { Say ('A visszaallitas sem sikerult: ' + $_.Exception.Message) }
    Say ('KEZZEL VISSZAALLITHATO diskpart-tal: select disk ' + $Disk + ' / clean / convert ' + $orig.ToLower() +
         ' / create partition primary offset=' + ($off / 1024) + ' size=' + [int64][math]::Ceiling($fsSize / $MB))
    return $false
}

# ---------------- FO RESZ ----------------
Log-Line ('Indul: mod=' + $Mode + ' lemez=' + $Disk + ' cel=' + $Target + ' Windows=' + $Win + ': zsugoritas=' + $ShrinkMB + ' MB')
$a = Analyze
if ($a.Err) { Finish 'ERR' $a.Err $null }
if ($a.Style -eq $Target) { Finish 'NOOP' ('a lemez mar ' + $Target) $null }
$drop = ($a.Drop -join ', ')
if ($Mode -ne 'run') { Finish 'OK' ('atalakithato: ' + $a.Style + '-rol ' + $Target + '-re') @{ DROP = $drop } }

$wp      = $a.Win
$orig    = $a.Style
$off     = [int64]$wp.Offset
$origGpt = [string]$wp.GptType
$sysLetter = Read-SysLetter

Say ('Windows particio: kezdete ' + $off + ' bajt, merete ' + $wp.Size + ' bajt, tabla ' + $orig)
Say ('Zsugoritas ' + $ShrinkMB + ' MB-tal...')
$want = [int64]$wp.Size - [int64]$ShrinkMB * $MB
try { Resize-Partition -DiskNumber $Disk -PartitionNumber $wp.PartitionNumber -Size $want -ErrorAction Stop }
catch { Finish 'ERR' ('a zsugoritas nem sikerult: ' + $_.Exception.Message) $null }
$script:Changed = $true
$wp = Get-Partition -DiskNumber $Disk -PartitionNumber $wp.PartitionNumber
$fsSize = [int64]$wp.Size
if ([int64]$wp.Offset -ne $off) { Finish 'ERR' 'a zsugoritas utan megvaltozott a particio kezdete - leallok' $null }
Say ('MENTO-ADAT (ha barmi felbeszakad): lemez ' + $Disk + ', eredeti tabla ' + $orig +
     ', Windows particio kezdete ' + $off + ' bajt, merete ' + $fsSize + ' bajt')

Say ('A particios tabla csereje ' + $Target + '-re...')
Run-Diskpart @(('select disk ' + $Disk), 'clean', ('convert ' + $Target.ToLower())) | Out-Null
Update-HostStorageCache -ErrorAction SilentlyContinue
$st = [string](Get-Disk -Number $Disk).PartitionStyle
if ($st -ne $Target) {
    $ok = Restore ('a diskpart nem alakitotta at a tablat (most: ' + $st + ')')
    Finish 'ERR' ('a tabla atalakitasa nem sikerult; visszaallitas: ' + $(if ($ok) { 'sikeres' } else { 'SIKERTELEN, lasd a logot' })) $null
}
try { $np = Make-WinPart $Target $BASIC }
catch {
    $e = $_.Exception.Message
    $ok = Restore ('a Windows particio visszairasa nem sikerult: ' + $e)
    Finish 'ERR' ($e + '; visszaallitas: ' + $(if ($ok) { 'sikeres' } else { 'SIKERTELEN, lasd a logot' })) $null
}
if (-not (Wait-Win)) {
    $ok = Restore 'a Windows particio a helyen van, de nem olvashato'
    Finish 'ERR' ('a Windows particio nem olvashato az atalakitas utan; visszaallitas: ' + $(if ($ok) { 'sikeres' } else { 'SIKERTELEN, lasd a logot' })) $null
}
Say ('A Windows particio a helyen van es olvashato (' + $Win + ':\Windows).')
$regOk = Fix-Registry $Target $np $sysLetter
$reg = '0'
if ($regOk) { $reg = '1' }
Finish 'OK' ('a lemez most ' + $Target) @{ REG = $reg; SYSLETTER = $sysLetter }
