#!/command/with-contenv sh

. /etc/s6-overlay/scripts/service-user.sh
hb_resolve_service_user

hb_source_trusted /opt/homebridge/source.sh

# run user defined custom startup script
if [ -f /homebridge/startup.sh ]; then
  chmod +x /homebridge/startup.sh 2> /dev/null
  cd /homebridge || exit 1

  if hb_startup_script_as_root; then
    if [ "$HB_SERVICE_USER" != "root" ] && ! hb_is_root_owned /homebridge/startup.sh; then
      echo "WARNING: HB_STARTUP_SCRIPT_AS_ROOT=1 but /homebridge/startup.sh is not owned by root; running it as the homebridge user instead."
      echo "WARNING: restart the container to take the script into root ownership."
      /command/s6-setuidgid homebridge /homebridge/startup.sh
    else
      echo "Executing user startup script /homebridge/startup.sh as root"
      /homebridge/startup.sh
    fi
  else
    echo "Executing user startup script /homebridge/startup.sh as the homebridge user (uid ${HB_SERVICE_UID}, gid ${HB_SERVICE_GID})"
    echo "Set HB_STARTUP_SCRIPT_AS_ROOT=1 to run it as root, e.g. if it installs packages with apt."
    /command/s6-setuidgid homebridge /homebridge/startup.sh
  fi
fi

exit 0
