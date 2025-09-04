#!/bin/sh
set -eu

ScriptName="Collect-Installed-Packages"
LogPath="/tmp/${ScriptName}-script.log"
ARLog="/var/ossec/logs/active-responses.log"
LogMaxKB=100
LogKeep=5
HostName="$(hostname)"
runStart="$(date +%s)"

WriteLog() {
  Message="$1"; Level="${2:-INFO}"
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  line="[$ts][$Level] $Message"
  printf '%s\n' "$line" >&2
  printf '%s\n' "$line" >> "$LogPath"
}

RotateLog() {
  [ -f "$LogPath" ] || return 0
  size_kb=$(du -k "$LogPath" | awk '{print $1}')
  [ "$size_kb" -le "$LogMaxKB" ] && return 0
  i=$((LogKeep-1))
  while [ $i -ge 0 ]; do
    [ -f "$LogPath.$i" ] && mv -f "$LogPath.$i" "$LogPath.$((i+1))"
    i=$((i-1))
  done
  mv -f "$LogPath" "$LogPath.1"
}

iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
escape_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

BeginNDJSON(){ TMP_AR="$(mktemp)"; }
AddRecord(){
  ts="$(iso_now)"
  typ="$1"; name="$2"; ver="$3"; shift 3
  base=$(printf '{"timestamp":"%s","host":"%s","action":"%s","copilot_action":true,"type":"%s","name":"%s","version":"%s"' \
         "$ts" "$HostName" "$ScriptName" "$(escape_json "$typ")" "$(escape_json "$name")" "$(escape_json "$ver")")
  while [ "$#" -ge 2 ]; do
    k="$(escape_json "$1")"; v="$(escape_json "$2")"
    base="$base,\"$k\":\"$v\""
    shift 2
  done
  printf '%s}\n' "$base" >> "$TMP_AR"
}
AddStatus(){
  ts="$(iso_now)"; st="${1:-info}"; msg="$(escape_json "${2:-}")"
  printf '{"timestamp":"%s","host":"%s","action":"%s","copilot_action":true,"status":"%s","message":"%s"}\n' \
    "$ts" "$HostName" "$ScriptName" "$st" "$msg" >> "$TMP_AR"
}

CommitNDJSON(){
  [ -s "$TMP_AR" ] || AddStatus "no_results" "no package data produced"
  AR_DIR="$(dirname "$ARLog")"
  [ -d "$AR_DIR" ] || WriteLog "Directory missing: $AR_DIR (will attempt write anyway)" WARN
  if mv -f "$TMP_AR" "$ARLog"; then
    WriteLog "Wrote NDJSON to $ARLog" INFO
  else
    WriteLog "Primary write FAILED to $ARLog" WARN
    if mv -f "$TMP_AR" "$ARLog.new"; then
      WriteLog "Wrote NDJSON to $ARLog.new (fallback)" WARN
    else
      keep="/tmp/active-responses.$$.ndjson"
      cp -f "$TMP_AR" "$keep" 2>/dev/null || true
      WriteLog "Failed to write both $ARLog and $ARLog.new; saved $keep" ERROR
      rm -f "$TMP_AR" 2>/dev/null || true
      exit 1
    fi
  fi
  for p in "$ARLog" "$ARLog.new"; do
    if [ -f "$p" ]; then
      sz=$(wc -c < "$p" 2>/dev/null || echo 0)
      ino=$(ls -li "$p" 2>/dev/null | awk '{print $1}')
      head1=$(head -n1 "$p" 2>/dev/null || true)
      WriteLog "VERIFY: path=$p inode=$ino size=${sz}B first_line=${head1:-<empty>}" INFO
    fi
  done
}

collect_apt_installed(){
  command -v dpkg-query >/dev/null 2>&1 || return 0
  dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | sort | \
  while IFS="$(printf '\t')" read -r name ver; do
    [ -n "$name" ] || continue
    AddRecord "installed" "$name" "${ver:--}" package_manager "apt"
  done
}
collect_apt_updates(){
  command -v apt >/dev/null 2>&1 || return 0
  apt list --upgradeable 2>/dev/null | awk 'NR>1' | while IFS= read -r line; do
    n="$(printf '%s' "$line" | awk -F'[/ ]+' '{print $1}')"
    v="$(printf '%s' "$line" | awk -F'[/ ]+' '{print $2}')"
    [ -n "$n" ] || continue
    [ -n "$v" ] || v="-"
    AddRecord "update" "$n" "$v" package_manager "apt"
  done
}
collect_apt_recent(){
  command -v dpkg-query >/dev/null 2>&1 || return 0
  d1="$(date --date='7 days ago' +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
  for f in /var/log/dpkg.log /var/log/dpkg.log.[0-9]*; do
    [ -f "$f" ] || continue
    grep ' install ' "$f" 2>/dev/null | awk -v d1="$d1" '$1>=d1' | \
    while IFS= read -r line; do
      pkg="$(printf '%s' "$line" | awk '{print $5}' | sed 's/:.*$//')"
      ver="$(printf '%s' "$line" | awk '{print $NF}')"
      [ -n "$pkg" ] || continue
      [ -n "$ver" ] || ver="-"
      AddRecord "recent_install" "$pkg" "$ver" package_manager "apt" source_log "$(basename "$f")"
    done
  done
}

collect_rpm_installed(){
  command -v rpm >/dev/null 2>&1 || return 0
  rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null | sort | \
  while IFS="$(printf '\t')" read -r name ver; do
    [ -n "$name" ] || continue
    AddRecord "installed" "$name" "${ver:--}" package_manager "rpm"
  done
}
collect_rpm_updates(){
  if command -v dnf >/dev/null 2>&1; then
    dnf check-update 2>/dev/null | awk '/^[[:alnum:]_.+-]+[[:space:]]/ {print $1, $2}' | \
    while read -r n v; do
      [ -n "$n" ] || continue
      [ -n "$v" ] || v="-"
      AddRecord "update" "$n" "$v" package_manager "rpm" updater "dnf"
    done || true
  elif command -v yum >/dev/null 2>&1; then
    yum check-update 2>/dev/null | awk '/^[[:alnum:]_.+-]+[[:space:]]/ {print $1, $2}' | \
    while read -r n v; do
      [ -n "$n" ] || continue
      [ -n "$v" ] || v="-"
      AddRecord "update" "$n" "$v" package_manager "rpm" updater "yum"
    done || true
  fi
}
collect_rpm_recent(){
  command -v rpm >/dev/null 2>&1 || return 0
  d1="$(date --date='7 days ago' +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
  for f in /var/log/yum.log /var/log/dnf.log /var/log/yum.log-* /var/log/dnf.log-*; do
    [ -f "$f" ] || continue
    grep -E 'Installed:' "$f" 2>/dev/null | awk -v d1="$d1" '$1>=d1' | \
    while IFS= read -r line; do
      pkg="$(printf '%s' "$line" | sed -n 's/^.*Installed:[[:space:]]\+\([^[:space:]]\+\).*/\1/p' | sed 's/-[0-9].*$//' )"
      vr="$(printf '%s' "$line" | sed -n 's/^.*Installed:[[:space:]]\+\([^[:space:]]\+\).*/\1/p' | sed 's/^[^-]*-//' )"
      [ -n "$pkg" ] || continue
      [ -n "$vr" ] || vr="-"
      AddRecord "recent_install" "$pkg" "$vr" package_manager "rpm" source_log "$(basename "$f")"
    done
  done
}

RotateLog
WriteLog "=== SCRIPT START : $ScriptName (host=$HostName) ==="
BeginNDJSON

if command -v dpkg-query >/dev/null 2>&1; then
  WriteLog "Detected APT (dpkg)" INFO
  collect_apt_installed || true
  collect_apt_updates || true
  collect_apt_recent || true
elif command -v rpm >/dev/null 2>&1; then
  WriteLog "Detected RPM" INFO
  collect_rpm_installed || true
  collect_rpm_updates || true
  collect_rpm_recent || true
else
  WriteLog "No supported package manager found." ERROR
  AddStatus "error" "no supported package manager found"
fi

CommitNDJSON
dur=$(( $(date +%s) - runStart ))
WriteLog "=== SCRIPT END : ${dur}s ==="
