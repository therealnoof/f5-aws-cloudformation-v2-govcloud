#!/bin/bash
# cluster-heal.sh - self-heal for the documented BIG-IP / Declarative Onboarding
# device-trust startup-timing bug: /Common/Root is not initialised on first boot,
# so DO clustering cannot bootstrap (errors "/Common/Root not found" /
# "/Common/failoverGroup not found") and the pair never clusters. See GOVCLOUD-GUIDE.md.
#
# F5's documented workaround is "reboot (Root rebuilds) -> re-apply clustering". This
# automates it, but does the re-apply as the PROVEN manual recovery rather than via DO,
# because DO's own clustering deadlocks here (its joiner never runs add-to-trust even
# once Root exists). Installed by the failover runtime-init pre_onboard hook and run by
# cron every few minutes. Idempotent, marker-gated (no reboot loops), self-disables
# once In Sync.
#
#   1. In Sync                  -> remove cron, mark done, exit.
#   2. hostname unset / early   -> wait (don't touch a half-onboarded device).
#   3. Root MISSING (the bug)   -> save config + reboot ONCE to rebuild Root.
#   4a. trust not formed:
#        - JOINER (rendered trust.remoteHost is an IP in the runtime-init log)
#          -> cluster-heal-trust.py: fetch admin password (Secrets Manager, SigV4 via
#             instance role) and POST /mgmt/tm/cm/add-to-trust to the peer.
#        - OWNER (remoteHost is a /Common path) -> wait for the joiner.
#   4a-bis. trust formed but config-sync stays Disconnected (TMM failed to load the
#        device-trust cert chain for the _ha_cgc HA profiles) -> restart TMM ONCE.
#   4b. trust formed -> elected owner (alphabetically-first device) creates failoverGroup
#        + force-syncs (plain tmsh, no password); each device acts on any
#        "Synchronize <me> to group X" recommendation (covers datasync-global-dg).
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH
S=/config/cluster-heal; mkdir -p "$S"; exec >>"$S/log" 2>&1
echo "=== $(date) cluster-heal ==="
RTILOG=/var/log/cloud/bigIpRuntimeInit.log

[ -f "$S/done" ] && { rm -f /etc/cron.d/cluster-heal; exit 0; }

# 1. Cluster healthy -> signal CloudFormation success, then disable self.
# Because clustering is bootstrapped out-of-band (this script), runtime-init exits
# non-zero on the clustering DO and its userdata never sends the success signal -- so
# we send it here once the cluster is actually In Sync. We reuse the SAME rendered
# "cfn-signal -e 0 --stack ... --resource ... --region ..." command CloudFormation put
# in the instance userdata (no new AWS calls/permissions). This keeps the DO declaration
# stock (DO stays the source of truth) and makes the stack succeed only when truly
# clustered (CREATE_FAILED via the CreationPolicy timeout otherwise).
if tmsh show cm sync-status 2>/dev/null | grep -qi "in sync"; then
  echo "cluster In Sync"
  if [ ! -f "$S/signalled" ]; then
    SIG=$(grep -ohE '/opt/aws/bin/cfn-signal -e 0 --stack [^ ]+ --resource [^ ]+ --region [^ ]+' \
          /opt/cloud/instance/user-data.txt /var/lib/cloud/instance/user-data.txt /config/cloud/user_data 2>/dev/null | head -1)
    if [ -n "$SIG" ]; then
      echo "signalling CloudFormation success: $SIG"
      if $SIG; then touch "$S/signalled"; echo "cfn-signal sent OK"; else echo "cfn-signal failed - will retry next tick"; exit 0; fi
    else
      echo "WARNING: cfn-signal command not found in userdata - cluster is up but stack relies on its own signal/timeout"
      touch "$S/signalled"
    fi
  fi
  echo "In Sync + signalled -> disabling self-heal"
  touch "$S/done"; rm -f /etc/cron.d/cluster-heal; exit 0
fi

# 2. Don't act until base onboarding has set the hostname
MYHOST=$(tmsh list sys global-settings hostname 2>/dev/null | awk '/hostname/{print $2}')
case "$MYHOST" in ""|localhost*|ip-*) echo "hostname not set yet ($MYHOST) - waiting"; exit 0;; esac

# Pre-reboot safety: let the initial onboard run a while before intervening
if [ ! -f "$S/rebooted" ]; then
  U=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
  [ "$U" -lt 600 ] && { echo "uptime ${U}s < 600s (pre-reboot guard) - waiting"; exit 0; }
fi

# 3. Is the local Root trust-domain present?
if ! tmsh list cm trust-domain Root one-line >/dev/null 2>&1; then
  if [ ! -f "$S/rebooted" ]; then
    echo "Root trust-domain MISSING after onboarding -> saving config + rebooting once to rebuild it"
    tmsh save sys config >/dev/null 2>&1
    touch "$S/rebooted"
    reboot
    exit 0
  fi
  U=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
  [ "$U" -lt 240 ] && { echo "post-reboot, waiting for Root to initialise (uptime ${U}s)"; exit 0; }
  echo "Root STILL missing >4min after reboot - manual recovery needed (see GOVCLOUD-GUIDE.md)"
  exit 0
fi

# 4a. Is device trust formed? (peer present => 2+ ca-devices in Root)
NTRUST=$(tmsh list cm trust-domain Root 2>/dev/null | grep -oE '/Common/[^ }]+\.local' | sort -u | wc -l)
if [ "${NTRUST:-0}" -lt 2 ]; then
  # The joiner's rendered trust.remoteHost is an IP (logged by runtime-init). The owner's
  # is a /Common/... path, so it has no IP here -> the owner just waits for the joiner.
  PEERIP=$(grep -oE '"remoteHost":"[0-9]{1,3}(\.[0-9]{1,3}){3}"' "$RTILOG" 2>/dev/null | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -1)
  if [ -z "$PEERIP" ]; then
    echo "no IP remoteHost in runtime-init log -> I am the owner; waiting for joiner to establish trust"
    exit 0
  fi
  PEERNAME=$(grep -oE '[A-Za-z0-9_-]+\.local' "$RTILOG" 2>/dev/null | sort -u | grep -vx "$MYHOST" | head -1)
  T=$(cat "$S/trust_tries" 2>/dev/null || echo 0)
  if [ "$T" -ge 6 ]; then
    echo "add-to-trust attempted ${T}x, trust still not formed - manual recovery needed (see GOVCLOUD-GUIDE.md)"
    exit 0
  fi
  echo $((T+1)) > "$S/trust_tries"
  echo "JOINER -> add-to-trust peer=${PEERIP} name=${PEERNAME} (attempt $((T+1)))"
  python3 /config/cluster-heal-trust.py "$PEERIP" "$PEERNAME"
  echo "add-to-trust attempt complete; re-check next tick"
  exit 0
fi

# 4a-bis. Trust is formed but the config-sync channel will not come up.
# Lab-observed 2026-09-10: TMM loads the _ha_cgc_clientssl / _ha_cgc_serverssl profiles - the
# SSL profiles for the HA config-sync channel - while installAuthorityTrust is still writing
# the device-trust certificates, fails with "cannot load key/cert/chain", and never retries.
# iQuery then opens a TCP connection to the peer and has no usable TLS, so every configuration
# check passes (trust formed, configsync-ip correct, port 4353 reachable) while no session ever
# forms. Both devices go Active, and the two waiting states below - "waiting for owner" on the
# peer and "waiting for In Sync" on the owner - never terminate.
#
# Restarting TMM makes it re-read the completed chain. The restart is NOT gated on the log
# signature: in the observed case only ONE device logged the _ha_cgc error, yet both needed the
# restart before config-sync recovered. The log check is diagnostic only. Gated instead on
# Disconnected persisting for several consecutive ticks, so a transient disconnect during normal
# cluster formation does not trigger it, and marker-gated so it happens at most once.
# "Disconnected" is what sync-status reports when the iQuery session between the devices is not
# established. It appears on BOTH devices, whichever mode they are in (high-availability on the
# owner, sync-only on a peer that has no failover device group yet), so this one test covers both.
if tmsh show cm sync-status 2>/dev/null | grep -qi "disconnected"; then

  # Count CONSECUTIVE disconnected ticks in a file, because each cron run is a separate process
  # and cannot remember the last one. The counter is deleted the moment sync is healthy (see the
  # else branch at the bottom), so this only ever counts an unbroken run of failures.
  DISC=$(cat "$S/disc_ticks" 2>/dev/null || echo 0)

  # Defensive: if the counter file is empty or somehow not a number, treat it as 0. Without this,
  # $((DISC + 1)) below would abort the script under "set -u" / arithmetic errors and the
  # self-heal would stop running entirely. '*[!0-9]*' matches any string containing a non-digit.
  case "$DISC" in ''|*[!0-9]*) DISC=0 ;; esac

  DISC=$((DISC + 1))
  echo "$DISC" > "$S/disc_ticks"

  # Diagnostic only - this does NOT decide whether to restart. The certificate error is the known
  # cause, but in the observed failure only one of the two devices logged it while both needed the
  # restart, so gating on it would skip the device that needs it most. Logging it either way tells
  # whoever reads this log afterwards which device hit the certificate race.
  if grep -q '_ha_cgc.*cannot load key/cert/chain' /var/log/ltm 2>/dev/null; then
    echo "config-sync Disconnected (tick ${DISC}); TMM logged a device-trust cert load failure (_ha_cgc)"
  else
    echo "config-sync Disconnected (tick ${DISC}); no _ha_cgc cert error logged on this device"
  fi

  # Restart TMM once, after 3 consecutive disconnected ticks. Cron runs this script every 3
  # minutes, so 3 ticks is roughly 9 minutes - long enough that a brief disconnect during normal
  # cluster formation is never mistaken for this fault, and short enough to leave plenty of room
  # inside the stack's 50-minute CreationPolicy timeout for the cluster to form afterwards.
  #
  # Restarting TMM interrupts data plane traffic. That is acceptable here and only here: this
  # branch is reached only when the cluster has never synced, which means the pair is not yet
  # serving a working HA configuration anyway.
  if [ "$DISC" -ge 3 ] && [ ! -f "$S/tmm_restarted" ]; then
    echo "Disconnected for ${DISC} consecutive ticks -> restarting TMM once to rebuild the HA SSL profiles"

    # Write the marker BEFORE restarting, not after. Restarting TMM can kill this script mid-run;
    # if the marker were written afterwards it might never be written at all, and every subsequent
    # tick would restart TMM again - an endless restart loop that would be far worse than the
    # deadlock this is fixing.
    touch "$S/tmm_restarted"

    tmsh restart sys service tmm >/dev/null 2>&1

    # Stop here rather than falling through to the group-creation logic below. TMM takes up to a
    # minute to come back, and any tmsh command issued in the meantime would act on an
    # inconsistent view of the system. The next cron tick re-evaluates from the top.
    echo "TMM restart issued; re-checking next tick"
    exit 0
  fi

  # Three more ticks (about 9 further minutes) after the restart with no improvement means this is
  # not the certificate race, or not only that. Say so plainly instead of continuing to log a
  # reassuring "waiting for In Sync" - that silence is exactly what made the original failure take
  # an hour to spot. Deliberately does NOT exit: the steps below are harmless and may still help.
  if [ "$DISC" -ge 6 ] && [ -f "$S/tmm_restarted" ]; then
    echo "STILL Disconnected after a TMM restart - manual recovery needed; see the air-gap guide,"
    echo "troubleshooting: 'Both devices are Active and Disconnected, and the self-heal loops forever'"
  fi

else
  # Sync is not Disconnected, so any previous run of failures is over. Clearing the counter is what
  # makes the threshold above mean "3 consecutive", not "3 in total since boot" - without this, a
  # few unrelated blips over a long uptime would eventually add up and restart TMM on a healthy pair.
  rm -f "$S/disc_ticks"
fi

# 4b. Trust formed. Ensure failoverGroup + sync via plain tmsh (no password).
# Elect owner = alphabetically-first device name; only the owner creates the group.
OWNER=$(tmsh list cm device one-line 2>/dev/null | awk '{print $3}' | sort | head -1)
if ! tmsh list cm device-group failoverGroup one-line >/dev/null 2>&1; then
  if [ "$MYHOST" = "$OWNER" ]; then
    DEVS=$(tmsh list cm device one-line 2>/dev/null | awk '{print $3}' | tr '\n' ' ')
    echo "trust formed; I am owner ($OWNER) -> creating failoverGroup with: $DEVS"
    tmsh create cm device-group failoverGroup type sync-failover 2>/dev/null
    tmsh modify cm device-group failoverGroup devices add { $DEVS } 2>/dev/null
    tmsh modify cm device-group failoverGroup auto-sync enabled network-failover enabled 2>/dev/null
    tmsh save sys config >/dev/null 2>&1
    sleep 5
    tmsh run cm config-sync force-full-load-push to-group failoverGroup 2>/dev/null
    echo "failoverGroup created + force-pushed; waiting for In Sync"
  else
    echo "trust formed; waiting for owner ($OWNER) to create failoverGroup"
  fi
  exit 0
fi

# 4c. The /LOCAL_ONLY folder must NOT belong to the sync device group. It holds the default
# route, whose gateway is the device's own external subnet gateway and therefore DIFFERS per
# Availability Zone. If the folder is assigned to failoverGroup, that route is synced to the
# peer, fails validation there ("01070330:3: Static route gateway <ip> is not directly
# connected via an interface"), and the cluster sits permanently in Sync Failed - config
# changes stop propagating, while failover itself keeps working, so it is easy to miss.
# Creating the device group out-of-band (which this script must do, because DO's clustering
# deadlocks) can leave the folder stamped with the new group. Lab-observed 2026-09-08.
# Idempotent, and runs on both devices because each has its own copy of the folder.
if tmsh list sys folder /LOCAL_ONLY 2>/dev/null | grep -q "device-group failoverGroup"; then
  echo "/LOCAL_ONLY is assigned to failoverGroup -> excluding it from config-sync"
  tmsh modify sys folder /LOCAL_ONLY device-group none traffic-group traffic-group-local-only 2>/dev/null
  tmsh save sys config >/dev/null 2>&1
fi

# device-group exists but not yet In Sync. Act on any sync recommendation for THIS device
# (covers datasync-global-dg / datasync-device groups; direction-correct).
tmsh show cm sync-status 2>/dev/null | grep -i "Synchronize this device to group" | while read -r line; do
  GRP=$(echo "$line" | sed -n 's/.*to group \([A-Za-z0-9_.-]*\).*/\1/p')
  [ -n "$GRP" ] && { echo "recommended: sync this device -> ${GRP}"; tmsh run cm config-sync to-group "$GRP" 2>/dev/null; }
done
echo "failoverGroup exists, waiting for In Sync"
exit 0
