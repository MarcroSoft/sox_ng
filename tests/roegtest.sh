#!/usr/bin/env bash
#
# Røgtest for en bygget sox_ng: kører den igennem de formater og rettelser,
# dette repo lægger oven på releasen, og fejler hvis noget af det ikke virker.
#
# Brug:  tests/roegtest.sh <katalog med exe'erne> [arbejdskatalog]
#
# Den køres af .github/workflows/build-sox_ng-mxe.yml på artefakten fra
# byggejobbet, men er med vilje også til at køre i hånden:
#
#   tests/roegtest.sh ~/Downloads/sox_ng-win64-mxe
#
# MXE krydsbygger på Linux, så byggejobbet kan ikke selv køre sin exe.
# Derfor ligger prøven her, og derfor er det værd at kunne tage den uden at
# skubbe en commit og vente en halv time — hvilket er præcis den vej, en
# Speex-fejl blev fundet og eftervist 2026-11-18.
#
# Afhænger af et POSIX-skal plus stat, cmp, od og awk. Git Bash på en
# Windows-runner har dem alle; så har enhver almindelig Linux også.

set -eu

if [ $# -lt 1 ]; then
  sed -n '3,20p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
  exit 2
fi

BIN=$1
if [ ! -d "$BIN" ]; then
  echo "$BIN er ikke et katalog" >&2
  exit 2
fi
BIN=$(cd "$BIN" && pwd)

# `replace' omdøber sox_ng.exe til sox.exe, men lader soxi_ng.exe være, så
# navnene slås op frem for at gættes. Uden .exe, så et build til andet end
# Windows også kan prøves — det meste af testen er ikke Windows-specifik.
find_exe() {
  for n in "$@"; do
    if [ -x "$BIN/$n" ] || [ -f "$BIN/$n" ]; then
      echo "$BIN/$n"
      return 0
    fi
  done
  echo "fandt ingen af $* i $BIN" >&2
  return 1
}
SOX=$(find_exe sox.exe sox_ng.exe sox sox_ng)
SOXI=$(find_exe soxi_ng.exe soxi_ng soxi.exe soxi)

if [ $# -ge 2 ]; then
  WORK=$2
  mkdir -p "$WORK"
else
  WORK=$(mktemp -d 2>/dev/null || mktemp -d -t roegtest)
fi
WORK=$(cd "$WORK" && pwd)

echo "sox:        $SOX"
echo "soxi:       $SOXI"
echo "arbejder i: $WORK"
echo
chmod +x "$SOX" "$SOXI" 2>/dev/null || true
cd "$WORK"

"$SOX" --version || true
"$SOX" -n -r 44100 -c 2 test.wav synth 1 sine 440 vol 0.5
ls -la test.wav
# soxi_ng er den strippede kopi, og den skifter kun opførsel på
# argv[0] — så den her viser både at kopien kører, og at den stadig
# opfører sig som soxi og ikke som sox.
"$SOXI" test.wav
# Opus-encodingen kommer fra releasen nu, men den har stadig ingen
# linje i configures opsummering: den afhænger af libopusenc, som
# configure leder efter uden at sige noget. Byggejobbet læser svaret
# i soxconfig.h; her kontrolleres det i praksis, for uden
# skrive-slottene nægter sox_ng at åbne .opus som output, og så
# falder rundturen wav -> opus -> wav. -r 48000 fordi opus-handleren
# kun tager 8/12/16/24/48 kHz; sox_ng lægger selv et rate-effekt ind.
# -C 96 = 96 kbps CBR.
"$SOX" test.wav -C 96 -r 48000 test.opus
ls -la test.opus
"$SOXI" test.opus
"$SOX" test.opus test-rundtur.wav
ls -la test-rundtur.wav
# 1 kbps: under sox_ng's eget gamle gulv på 6, og dermed beviset på
# at det udvidede interval er med — det kom fra en patch her
# indtil 14.8.1, og ligger i selve src/opus.c fra 14.9.0. -V3 viser hvad encoderen fik at vide.
"$SOX" -V3 test.wav -C -1 -r 48000 lav.opus
ls -la lav.opus
"$SOXI" lav.opus
"$SOX" lav.opus lav-rundtur.wav
ls -la lav-rundtur.wav
# Og over det gamle loft på 256. libopus klamper selv ved 300 per
# kanal, så filen bliver ikke 400 kbps — pointen er at den skrives.
"$SOX" -V3 test.wav -C 400 -r 48000 hoej.opus
ls -la hoej.opus
"$SOXI" hoej.opus
# Speex. Skrivning findes kun med patchen, og læsning gik før den
# gennem ffmpeg-pipen. --help-format afslører hvilken handler der
# svarer på endelsen: står der "Ogg Speex", er det den native; stod
# der ffmpeg's tekst, havde rækkefølgen i formats.h tabt.
"$SOX" --help-format spx
if ! "$SOX" --help-format spx | grep -q "Ogg Speex"; then
  echo "spx besvares ikke af den native handler"
  exit 1
fi
# Speex tager kun 8, 16 og 32 kHz uden at brokke sig, så -r 16000;
# sox_ng lægger selv rate-effekten ind. Rundturen er tabsgivende,
# men granulepos i sidste Ogg-side siger præcis hvor mange samples
# der er, og både encoder og decoder skal ramme det tal.
"$SOX" test.wav -r 16000 roegtest-16k.wav
"$SOX" roegtest-16k.wav roegtest.spx
ls -la roegtest.spx
"$SOXI" roegtest.spx
"$SOX" roegtest.spx roegtest-rundtur.wav
ind=$("$SOXI" -s roegtest-16k.wav)
ud=$("$SOXI" -s roegtest-rundtur.wav)
echo "samples ind: $ind, ud: $ud"
if [ "$ind" != "$ud" ]; then
  echo "Speex-rundturen tabte eller tilføjede samples"
  exit 1
fi
# Og så justeringen, som antallet af samples ikke siger noget om.
# Speex er tabsgivende, så lyden kommer ikke ens tilbage — men den
# skal komme tilbage på rette tid. Testen er derfor ikke en
# tærskel, men en sammenligning: passer en forskydning bedre end
# ingen forskydning, er afkodningen tidsforskudt.
#
# Hvidstøj med vilje. En tone gentager sig — 440 Hz ved 16 kHz hver
# 36. sample — og passer derfor lige godt ved en hel række
# forskydninger, så en tone kan slet ikke måle det her. Det var
# netop den fælde, der i første omgang fik en forskydning på 223
# samples til at se ud som 40.
#
# 223 er med i rækken, fordi det er den fejl, handleren havde:
# encoderens 143 plus decoderens 80 i wideband-tilstand.
"$SOX" -n -r 16000 -c 1 just.wav synth 1 whitenoise vol 0.5
"$SOX" just.wav just.spx
"$SOX" just.spx just-ud.wav
"$SOX" just.wav just-klip.wav trim 0 15000s
rms() {  # rms <forskydning i samples>
  "$SOX" just-ud.wav skubbet.wav trim "$1"s 15000s 2>/dev/null
  "$SOX" -m just-klip.wav -v -1 skubbet.wav forskel.wav 2>/dev/null
  "$SOX" forskel.wav -n stat 2>&1 | sed -n 's/^RMS *amplitude: *//p'
}
r0=$(rms 0)
echo "RMS-forskel uden forskydning: $r0"
# 0.9-margenen er mod numerisk vippen: to forskydninger, der begge
# er forkerte, lander på omtrent samme RMS, og så kan den ene godt
# komme et par promille under den anden uden at betyde noget. En
# rigtig fejljustering er ikke i nærheden af marginal — målt på den
# fejl, der var her, var 223 samples 0.086 mod 0.216.
for k in 64 128 223 256; do
  rk=$(rms "$k")
  echo "  forskudt $k samples: $rk"
  if awk "BEGIN{exit !($rk < 0.9 * $r0)}"; then
    echo "Speex-afkodningen er tidsforskudt: $k samples passer"
    echo "klart bedre end ingen forskydning ($rk mod $r0)."
    exit 1
  fi
done
echo "ok: Speex-rundturen er paa rette tid"
# Fra en pipe er filen ikke søgbar, så handleren kan hverken læse
# sidste sides granulepos på forhånd eller spole tilbage. Først
# kontrolleres at pipe-læsning overhovedet virker i dette miljø —
# med w64devkit's runtime falder sox_ng's stdin-læsning fra hinanden
# for alle formater, wav inklusive, og så siger en fejl her intet om
# Speex. Virker wav, skal spx også virke.
if cat roegtest-16k.wav | "$SOX" -t wav - pipe-wav.wav 2>/dev/null &&
   [ "$("$SOXI" -s pipe-wav.wav)" = "$ind" ]; then
  cat roegtest.spx | "$SOX" -t spx - pipe-rundtur.wav
  udp=$("$SOXI" -s pipe-rundtur.wav)
  echo "samples fra pipe: $udp"
  if [ "$udp" != "$ud" ]; then
    echo "Speex fra pipe gav $udp samples, fra fil $ud"
    exit 1
  fi
  echo "ok: ogsaa korrekt fra en pipe"
else
  echo "springer pipe-testen over: stdin-laesning virker ikke her i det hele taget"
fi
# -C er pakket som i opus.c: heltalsdelen er kvaliteten 0-10,
# fortegnet vælger CBR eller VBR (negativ er VBR), og decimaldelen
# er encoderens complexity 0-10, hvor intet komma betyder 10.
"$SOX" -V3 roegtest-16k.wav -c 1 -C 3 lav-q.spx
"$SOX" -V3 roegtest-16k.wav -c 1 -C 10 hoej-q.spx
"$SOX" -V3 roegtest-16k.wav -c 1 -C -8 vbr.spx
"$SOX" -V3 roegtest-16k.wav -c 1 -C 8.3 komp3.spx
"$SOX" -V3 roegtest-16k.wav -c 1 -C 8 komp10.spx
ls -la lav-q.spx hoej-q.spx vbr.spx komp3.spx komp10.spx
if [ "$(stat -c%s lav-q.spx)" -ge "$(stat -c%s hoej-q.spx)" ]; then
  echo "-C slår ikke igennem: kvalitet 3 fylder ikke mindre end 10"
  exit 1
fi
# Complexity ændrer kun hvor grundigt encoderen søger, ikke bitraten,
# så de to filer skal fylde det samme og alligevel være forskellige.
# Var complexity tavst faldet på gulvet, ville de være ens.
if [ "$(stat -c%s komp3.spx)" != "$(stat -c%s komp10.spx)" ]; then
  echo "complexity ændrede bitraten, hvilket den ikke skal"
  exit 1
fi
if cmp -s komp3.spx komp10.spx; then
  echo "-C 8.3 og -C 8 gav samme fil: complexity slår ikke igennem"
  exit 1
fi
# Fortegnet skal skifte tilstand; -V3 siger selv hvilken det blev.
if ! "$SOX" -V3 roegtest-16k.wav -c 1 -C -8 vbr2.spx 2>&1 |
     grep -q "VBR"; then
  echo "-C -8 gav ikke VBR"
  exit 1
fi
# Uden for 0-10 skal begge fortegn afvises.
for ugyldig in 11 -11; do
  if "$SOX" roegtest-16k.wav -C $ugyldig ugyldig.spx 2>/dev/null; then
    echo "-C $ugyldig blev accepteret, men skulle vaere afvist"
    exit 1
  fi
done
# MP3 i en RIFF-indpakning, fmt-kode 0x0055. Ingen af de encodere,
# der er med her, laver sådan en fil, så den bygges i hånden: sox_ng
# koder lyden til MP3, og resten er ren header. le() skriver et tal
# ud som rå little-endian bytes. Vejen om ad "%b" og "\0nnn" er den
# der virker: kommandosubstitutionen giver teksten "000", som printf
# så laver om til en NUL-byte — omvendt ville NUL'en falde på gulvet
# undervejs, for kommandosubstitution kan ikke bære den.
"$SOX" test.wav -C 128 roegtest.mp3
le() {  # le <tal> <antal bytes>
  local v=$1 n=$2 i
  for ((i = 0; i < n; i++)); do
    printf '%b' "\0$(printf '%03o' $(( (v >> (8 * i)) & 255 )))"
  done
}
mp3size=$(stat -c%s roegtest.mp3)
samples=$("$SOXI" -s test.wav)
{
  printf 'RIFF'; le $((4 + 8+30 + 8+4 + 8+mp3size)) 4; printf 'WAVE'
  printf 'fmt '; le 30 4
  le 85 2         # wFormatTag = WAVE_FORMAT_MPEGLAYER3
  le 2 2          # nChannels
  le 44100 4      # nSamplesPerSec
  le 16000 4      # nAvgBytesPerSec = 128 kbps
  le 1 2          # nBlockAlign
  le 0 2          # wBitsPerSample: 0, som i alle den slags filer
  le 12 2         # cbSize: resten er MPEGLAYER3WAVEFORMAT
  le 1 2          # wID = MPEGLAYER3_ID_MP3
  le 2 4          # fdwFlags = MPEGLAYER3_FLAG_PADDING_OFF
  le 1 2          # nBlockSize
  le 1 2          # nFramesPerBlock
  le 1393 2       # nCodecDelay
  printf 'fact'; le 4 4; le $((samples / 2)) 4
  printf 'data'; le $mp3size 4
} > mp3i.wav
cat roegtest.mp3 >> mp3i.wav
"$SOXI" mp3i.wav
if ! "$SOXI" -e mp3i.wav | grep -qi MPEG; then
  echo "0x0055 blev ikke genkendt som MPEG-lyd"
  exit 1
fi
# Den samme MP3-strøm med og uden RIFF-indpakningen skal give
# nøjagtig den samme lyd ud. Det er hele pointen, og det er også
# den eneste facitliste vi har, når encoderens forsinkelse er med.
"$SOX" mp3i.wav mp3i-ud.wav
"$SOX" roegtest.mp3 bar-ud.wav
echo "samples: indpakket $("$SOXI" -s mp3i-ud.wav), bar $("$SOXI" -s bar-ud.wav)"
if ! cmp mp3i-ud.wav bar-ud.wav; then
  echo "MP3 i wav gav ikke det samme som den bare mp3"
  exit 1
fi
# Og en kopi med en chunk hængt bag data-chunken, fyldt med 0xff,
# som ligner starten på et MPEG-sync-ord. Uden ft->data_end læser
# libmad videre ind i den og lægger en ramme støj til.
cp mp3i.wav mp3i-hale.wav
{ printf 'LIST'; le 44 4; printf 'INFO'
  printf 'ISFT'; le 32 4; head -c 32 /dev/zero | tr '\000' '\377'
} >> mp3i-hale.wav
"$SOX" mp3i-hale.wav hale-ud.wav
if ! cmp hale-ud.wav mp3i-ud.wav; then
  echo "en chunk efter data-chunken slap med ind i lyden"
  exit 1
fi
echo "ok: MP3 i RIFF-indpakning, ogsaa med en chunk bagefter"
# Spoling: seek_wav sender den videre til seek_mad, som tæller
# rammer fra ft->data_start og ikke fra filens begyndelse.
"$SOX" mp3i.wav klip-indpakket.wav trim 0.4
"$SOX" roegtest.mp3 klip-bar.wav trim 0.4
cmp klip-indpakket.wav klip-bar.wav
echo "ok: trim rammer det samme sted i begge"

# Og den anden vej: -t wavmp3 lægger MP3'en i data-chunken selv.
"$SOX" test.wav -t wavmp3 skriv.wav
"$SOXI" skriv.wav
if ! "$SOXI" -e skriv.wav | grep -qi MPEG; then
  echo "-t wavmp3 skrev ikke MPEG-lyd"
  exit 1
fi
# Samme lyd som en bar mp3 med samme indstillinger. Det er den
# eneste facitliste der findes, når encoderens egen forsinkelse er
# med i tallet, og den viser samtidig at det er den samme encoder.
"$SOX" test.wav bar.mp3
"$SOX" skriv.wav skriv-ud.wav
"$SOX" bar.mp3 bar-mp3-ud.wav
if ! cmp skriv-ud.wav bar-mp3-ud.wav; then
  echo "-t wavmp3 gav ikke samme lyd som en bar mp3"
  exit 1
fi
# VBR. Her spoler LAME tilbage til starten af MPEG-strømmen for at
# skrive sin Xing-ramme; uden ft->data_start lander den skrivning
# oven i RIFF-headeren, og så er filen ikke en wav længere.
"$SOX" test.wav -C -2 -t wavmp3 vbr.wav
if [ "$(head -c 4 vbr.wav)" != "RIFF" ]; then
  echo "VBR-taggen blev skrevet oven i RIFF-headeren"
  head -c 16 vbr.wav | od -An -tx1
  exit 1
fi
"$SOX" vbr.wav vbr-ud.wav
ls -la skriv.wav vbr.wav
# Og det vigtigste: det her må ikke smitte af på almindelig
# wav-udskrivning. `sox_ng x.mp3 x.wav` skal stadig give PCM, ikke en
# MP3 i en RIFF-indpakning. Det er hele grunden til at wavmp3 er en
# handler for sig.
"$SOX" bar.mp3 fra-mp3.wav
if ! "$SOXI" -e fra-mp3.wav | grep -qi "Signed Integer PCM"; then
  echo "mp3 ind gav ikke PCM ud i en almindelig .wav:"
  "$SOXI" fra-mp3.wav
  exit 1
fi
echo "ok: -t wavmp3 skriver, og almindelig .wav er uroert"

# Glob med danske tegn i navnet. Uden win32-glob-rettelsen får
# sox_ng navnet tilbage fra Windows i CP1252, mens dens egen fopen
# venter UTF-8, og det her fejler med "No such file or directory".
cp test.wav "røgtest æøå.wav"
"$SOX" "røgtest*.wav" -n
# Og den anden vej: danske tegn i selve mønsteret.
"$SOX" "røgtest æøå.*" -n

echo
echo "roegtesten gik igennem."
