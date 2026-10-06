# Shared helper for resolving the user the Homebridge service runs as.
#
# This file is sourced, not executed.
#
# PUID / PGID are optional. When either is set to a non-zero value, the
# Homebridge service runs as the "homebridge" user, remapped to that uid / gid.
# When both are unset - or either is 0 - Homebridge runs as root, which is the
# behaviour of every image since the 2022-06-24 release.
#
# See https://github.com/homebridge/docker-homebridge/issues/750

HB_SERVICE_USER=root
HB_SERVICE_UID=0
HB_SERVICE_GID=0

# Returns 0 when the service should run as the homebridge user, 1 when it
# should run as root. On success HB_SERVICE_USER, HB_SERVICE_UID and
# HB_SERVICE_GID describe the requested user.
hb_resolve_service_user() {
  HB_SERVICE_USER=root
  HB_SERVICE_UID=0
  HB_SERVICE_GID=0

  if [ -z "$PUID" ] && [ -z "$PGID" ]; then
    return 1
  fi

  # if only one of the two is set, use it for both
  hb_uid="${PUID:-$PGID}"
  hb_gid="${PGID:-$PUID}"

  case "${hb_uid}:${hb_gid}" in
    *[!0-9:]*)
      echo "WARNING: PUID / PGID must be numeric (got PUID=${PUID} PGID=${PGID}); the Homebridge service will run as root."
      return 1
      ;;
  esac

  # PUID / PGID of 0 means the user explicitly wants to run as root
  if [ "$hb_uid" -eq 0 ] || [ "$hb_gid" -eq 0 ]; then
    return 1
  fi

  HB_SERVICE_USER=homebridge
  HB_SERVICE_UID="$hb_uid"
  HB_SERVICE_GID="$hb_gid"
  return 0
}

# Takes ownership of the paths passed as arguments so the Homebridge service
# can write to them. A no-op when running as root. Returns non-zero if the
# ownership could not be changed, in which case the caller should fall back to
# running Homebridge as root.
#
# Note: /opt/homebridge is deliberately NOT passed to this function. It holds
# scripts this container sources as root (source.sh, source-docker.sh), so
# handing it to an unprivileged service user would let a compromised plugin
# gain root on the next container start. Plugins are installed into
# /var/lib/homebridge/node_modules (a symlink to /homebridge) and Homebridge,
# the UI and Node.js are updated through apt, so nothing the service user does
# needs to write there.
hb_fix_permissions() {
  if [ "$HB_SERVICE_USER" = "root" ]; then
    return 0
  fi

  chown -R "${HB_SERVICE_UID}:${HB_SERVICE_GID}" "$@"
}

# Returns 0 when a file is safe for this container to run or source as root,
# i.e. it is owned by root and not writable by group or other. Anything else is
# writable by the unprivileged service user - and therefore by any Homebridge
# plugin - so executing it as root would hand that plugin the root user.
hb_is_root_owned() {
  hb_path="$1"

  [ -e "$hb_path" ] || return 1

  hb_owner="$(stat -c '%u' "$hb_path" 2> /dev/null)"
  if [ "$hb_owner" != "0" ]; then
    return 1
  fi

  # -perm /022 matches when the group-write or other-write bit is set
  if [ -n "$(find "$hb_path" -maxdepth 0 -perm /022 2> /dev/null)" ]; then
    return 1
  fi

  return 0
}

# Sources a file as root, but only when it passes hb_is_root_owned. Missing
# files are skipped silently, untrusted ones with a warning.
hb_source_trusted() {
  hb_file="$1"

  [ -f "$hb_file" ] || return 0

  if ! hb_is_root_owned "$hb_file"; then
    echo "WARNING: refusing to source ${hb_file} as root because it is not owned by root or is writable by others."
    echo "WARNING: restore it with 'chown root:root ${hb_file} && chmod 755 ${hb_file}' if the contents are trusted."
    return 1
  fi

  echo "Sourcing ${hb_file}"
  . "$hb_file"
}

# Returns 0 when /homebridge/startup.sh should be executed as root.
#
# When PUID / PGID are set the startup script runs as the service user by
# default: it lives on the user's volume and is editable from the Homebridge UI,
# so running it as root would make write access to /homebridge equivalent to
# root. Set HB_STARTUP_SCRIPT_AS_ROOT=1 to keep the historical root behaviour -
# needed for startup scripts that install packages with apt - in which case the
# script is taken into root ownership so the service user can no longer edit it.
hb_startup_script_as_root() {
  if [ "$HB_SERVICE_USER" = "root" ]; then
    return 0
  fi

  [ "$HB_STARTUP_SCRIPT_AS_ROOT" = "1" ]
}

# Takes /homebridge/startup.sh into root ownership when it is going to be run
# as root, so that it cannot be rewritten by the service user between now and
# the next container start. Call after hb_fix_permissions, which chowns the
# whole of /homebridge.
hb_protect_startup_script() {
  hb_startup="/homebridge/startup.sh"

  [ -e "$hb_startup" ] || return 0

  if hb_startup_script_as_root && [ "$HB_SERVICE_USER" != "root" ]; then
    echo "HB_STARTUP_SCRIPT_AS_ROOT=1: taking ${hb_startup} into root ownership so it cannot be modified by the homebridge user."
    chown root:root "$hb_startup" 2> /dev/null
    chmod 755 "$hb_startup" 2> /dev/null
  fi
}

# Writes the sudo rules the Homebridge UI needs for the service user.
#
# The UI only ever runs a fixed set of privileged commands:
#
#   sudo kill 1                                                restart the container
#   sudo -n kill -9 <pid>                                      close a terminal session
#   sudo -n ... apt-get update                                 update Homebridge / Node.js
#   sudo -n ... apt-get install --only-upgrade -y homebridge    (both, on this image)
#   sudo -n shutdown -r now / -h now                           restart / shutdown buttons
#
# so only those are granted rather than full root. This is defence in depth
# against a compromised plugin, not a security boundary: apt runs maintainer
# scripts as root. SETENV is required because the UI passes
# HOMEBRIDGE_CONFIG_UI_TERMINAL=0 through sudo.
#
# Set HB_SUDO_UNRESTRICTED=1 to fall back to unrestricted sudo, should a future
# version of the UI need a command that is not listed here.
#
# The rule is written by uid as well as by name, because the requested uid may
# be shared with another account - the "ubuntu" user owns 1000:1000 on Ubuntu
# 24.04 - in which case sudo resolves the process to that account instead.
hb_write_sudoers() {
  hb_sudoers=/etc/sudoers.d/010_homebridge-nopasswd

  if [ "$HB_SUDO_UNRESTRICTED" = "1" ]; then
    echo "WARNING: HB_SUDO_UNRESTRICTED=1 - granting the homebridge user unrestricted sudo."
    printf '%s\n' \
      "homebridge ALL=(ALL) NOPASSWD:SETENV: ALL" \
      "#${HB_SERVICE_UID} ALL=(ALL) NOPASSWD:SETENV: ALL" \
      > "$hb_sudoers"
  else
    printf '%s\n' \
      "# the privileged commands the Homebridge UI runs - see README.md" \
      "Cmnd_Alias HB_RESTART_CONTAINER = /usr/bin/kill 1, /bin/kill 1" \
      "Cmnd_Alias HB_TERMINAL_KILL = /usr/bin/kill -9 [1-9]*, /bin/kill -9 [1-9]*" \
      "Cmnd_Alias HB_UPDATE = /usr/bin/apt-get update, /usr/bin/apt-get install --only-upgrade -y homebridge" \
      "Cmnd_Alias HB_POWER = /usr/sbin/shutdown -r now, /usr/sbin/shutdown -h now, /sbin/shutdown -r now, /sbin/shutdown -h now" \
      "" \
      "homebridge ALL=(ALL) NOPASSWD:SETENV: HB_RESTART_CONTAINER, HB_TERMINAL_KILL, HB_UPDATE, HB_POWER" \
      "#${HB_SERVICE_UID} ALL=(ALL) NOPASSWD:SETENV: HB_RESTART_CONTAINER, HB_TERMINAL_KILL, HB_UPDATE, HB_POWER" \
      > "$hb_sudoers"
  fi

  chown root:root "$hb_sudoers"
  chmod 0440 "$hb_sudoers"

  # a malformed file breaks sudo for every user, so validate it and drop it if
  # the check fails rather than leaving the container without working sudo
  if ! visudo -cf "$hb_sudoers" > /dev/null 2>&1; then
    echo "WARNING: generated ${hb_sudoers} failed validation and has been removed; the Homebridge UI will not be able to restart the container or apply updates."
    rm -f "$hb_sudoers"
    return 1
  fi
}
