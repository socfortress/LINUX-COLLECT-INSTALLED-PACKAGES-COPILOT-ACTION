#!/bin/sh
set -eu

ScriptName="Collect-Installed-Packages"
LogPath="/tmp/${ScriptName}-script.log"
ARLog="/var/ossec/active-response/active-responses.log"
LogMaxKB=100
LogKeep=5
HostName="$(hostname)"
runStart="$(date +%s)"

WriteLog() {
  Message="$1"; Level="${2:-INFO}"
  ts="$(date '+%Y-%m-%d %H:%M:%S%z')"
  line="[$ts][$Level] $Message"
  printf '%s\n' "$line" >&2
  printf '%s\n' "$line" >> "$LogPath"
}

RotateLog() {
  [ -f "$LogPath" ] || return 0
  size_kb="$(awk -v s="$(wc -c <"$LogPath")" 'BEGIN{printf "%.0f", s/1024}')"
  [ "$size_kb" -le "$LogMaxKB" ] && return 0
  i=$((LogKeep-1))
  while [ $i -ge 1 ]; do
    src="$LogPath.$i"; dst="$LogPath.$((i+1))"
    [ -f "$src" ] && mv -f "$src" "$dst" || true
    i=$((i-1))
  done
  mv -f "$LogPath" "$LogPath.1"
}

escape_json() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

BeginNDJSON() {
  TMP_AR="$(mktemp)"
}

AddRecord() {
  ts="$(date '+%Y-%m-%d %H:%M:%S%z')"
  typ="$(escape_json "$1")"; shift
  name="$(escape_json "$1")"; shift
  ver="$(escape_json "$1")"; shift

  base="$(printf '{"timestamp":"%s","host":"%s","action":"%s","copilot_action":true,"type":"%s","name":"%s","version":"%s"' \
      "$ts" "$HostName" "$ScriptName" "$typ" "$name" "$ver")"

  while [ "$#" -ge 2 ]; do
    k="$(escape_json "$1")"; v="$(escape_json "$2")"
    base="$base,\"$k\":\"$v\""
    shift 2
  done

  printf '%s}\n' "$base" >> "$TMP_AR"
}

AddError() {
  ts="$(date '+%Y-%m-%d %H:%M:%S%z')"
  msg="$(escape_json "$1")"
  printf '{"timestamp":"%s","host":"%s","action":"%s","copilot_action":true,"status":"error","message":"%s"}\n' \
    "$ts" "$HostName" "$ScriptName" "$msg" >> "$TMP_AR"
}

CommitNDJSON() {
  if [ ! -s "$TMP_AR" ]; then
    AddError "No package data produced"
  fi

  if mv -f "$TMP_AR" "$ARLog" 2>/dev/null; then
    :
  else
    mv -f "$TMP_AR" "$ARLog.new" 2>/dev/null || printf '{"timestamp":"%s","host":"%s","action":"%s","copilot_action":true,"status":"error","message":"atomic move failed"}\n' \
      "$(date '+%Y-%m-%d %H:%M:%S%z')" "$HostName" "$ScriptName" > "$ARLog.new"
  fi
}

collect_apt_installed() {
  dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | sort | while IFS="$(printf '\t')" read -r name ver; do
    [ -n "$name" ] || continue
    AddRecord "installed" "$name" "${ver:--}" package_manager "apt"
  done
}

collect_apt_updates() {
  if command -v apt >/dev/null 2>&1; then
    apt list --upgradeable 2>/dev/null | awk 'NR>1' | while IFS= read -r line; do
      n="$(printf '%s' "$line" | awk -F'[/ ]+' '{print $1}')"
      v="$(printf '%s' "$line" | awk -F'[/ ]+' '{print $2}')"
      [ -n "$n" ] || continue
      [ -n "$v" ] || v="-"
      AddRecord "update" "$n" "$v" package_manager "apt"
    done
  fi
}

collect_apt_recent() {
  d1="$(date --date='7 days ago' +%Y-%m-%d 2>/dev/null || date '+%Y-%m-%d')" 
  for f in /var/log/dpkg.log /var/log/dpkg.log.[0-9]*; do
    [ -f "$f" ] || continue
    grep ' install ' "$f" 2>/dev/null | awk -v d1="$d1" '$1>=d1' | while IFS= read -r line; do
      pkg="$(printf '%s' "$line" | awk '{print $5}' | sed 's/:.*$//')"
      ver="$(printf '%s' "$line" | awk '{print $NF}')"
      [ -n "$pkg" ] || continue
      [ -n "$ver" ] || ver="-"
      AddRecord "recent_install" "$pkg" "$ver" package_manager "apt" source_log "$(basename "$f")"
    done
  done
}

collect_rpm_installed() {
  rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null | sort | while IFS="$(printf '\t')" read -r name ver; do
    [ -n "$name" ] || continue
    AddRecord "installed" "$name" "${ver:--}" package_manager "rpm"
  done
}

collect_rpm_updates() {
  if command -v dnf >/dev/null 2>&1; then
    dnf check-update 2>/dev/null | awk '/^[[:alnum:]_.+-]+[[:space:]]/ {print $1, $2}' | while read -r n v; do
      [ -n "$n" ] || continue
      [ -n "$v" ] || v="-"
      AddRecord "update" "$n" "$v" package_manager "rpm" updater "dnf"
    done || true
  elif command -v yum >/dev/null 2>&1; then
    yum check-update 2>/dev/null | awk '/^[[:alnum:]_.+-]+[[:space:]]/ {print $1, $2}' | while read -r n v; do
      [ -n "$n" ] || continue
      [ -n "$v" ] || v="-"
      AddRecord "update" "$n" "$v" package_manager "rpm" updater "yum"
    done || true
  fi
}

collect_rpm_recent() {
  d1="$(date --date='7 days ago' +%Y-%m-%d 2>/dev/null || date '+%Y-%m-%d')"
  for f in /var/log/yum.log /var/log/dnf.log /var/log/yum.log-* /var/log/dnf.log-*; do
    [ -f "$f" ] || continue
    grep -E 'Installed:' "$f" 2>/dev/null | awk -v d1="$d1" '$1>=d1' | while IFS= read -r line; do
      pkg="$(printf '%s' "$line" | sed -n 's/^.*Installed:[[:space:]]\+\([^[:space:]]\+\).*/\1/p' | sed 's/-[0-9].*$//' )"
      vr="$(printf '%s' "$line" | sed -n 's/^.*Installed:[[:space:]]\+\([^[:space:]]\+\).*/\1/p' | sed 's/^[^-]*-//' )"
      [ -n "$pkg" ] || continue
      [ -n "$vr" ] || vr="-"
      AddRecord "recent_install" "$pkg" "$vr" package_manager "rpm" source_log "$(basename "$f")"
    done
  done
}

RotateLog
WriteLog "START $ScriptName"
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
  AddError "No supported package manager found"
fi

CommitNDJSON

dur=$(( $(date +%s) - runStart ))
WriteLog "END $ScriptName in ${dur}s"
