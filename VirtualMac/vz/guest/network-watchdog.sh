#!/bin/sh
#
# Virtual Mac guest network watchdog
#
# Runs inside the macOS guest of "Virtual Mac on iPad". Detects the state that
# breaks after the *host* (iPad) changes network, and repairs it without the
# user having to disable/re-enable the adapter by hand.
#
# Why polling instead of a link/path event:
#   The guest NIC is virtio. Its link never drops and its IPv4 address/subnet
#   normally stays valid, so neither an interface status change nor
#   NWPathMonitor reports anything when the iPad switches Wi-Fi. The only
#   reliable in-guest symptom is that the default gateway stops answering.
#
# Detection:
#   Ping the *default gateway* (the host bridge or the real LAN router), not the
#   internet. This deliberately distinguishes "guest-side state is stale" from
#   "the iPad itself is offline": if the iPad has no uplink but the link is
#   healthy, the gateway still answers and we do nothing.
#   Once a probe fails, polling speeds up so a real outage is confirmed in
#   about a second instead of a full interval per probe.
#
# Repair ladder (cheapest first, stops as soon as the gateway answers):
#   1. flush the stale ARP entry and force a re-probe
#   2. renew the DHCP lease   (same as System Settings > Renew DHCP Lease)
#   3. bounce the interface   (link layer restart plus a fresh discover)
#   4. toggle the network service (same as the manual adapter off/on)
#
#   Every step waits for the gateway to come back before the next one runs, and
#   records how long it took, so a slow recovery can be attributed to a
#   specific step instead of guessed at. Confirming a step costs a probe, and a
#   probe that gets no answer is not cheap, so the ladder only pays for the
#   confirmations that can actually change the outcome.
#
# Optional config file: /Library/VirtualMac/network-watchdog.conf
#   INTERVAL=2          seconds between health checks while healthy
#   FAILS=2             consecutive failures before repairing
#   INTERFACE=en0       force an interface (default: autodetect)
#   SAFETY_RENEW=0      seconds between unconditional DHCP renews (0 = off)
#   MAX_BACKOFF=60      slowest retry interval after repeated failures
#   PING_WAIT=200       milliseconds to wait for a probe reply
#   RENEW_WAIT=1        seconds to wait after a DHCP renew
#   BOUNCE_WAIT=15      seconds to wait after bouncing the interface
#   SERVICE_WAIT=15     seconds to wait after toggling the network service
#   FRESH_DISCOVER=1    clear the address before renewing after a bounce, so
#                       the client runs a fresh DHCP discover instead of a
#                       renew aimed at a server that may be unreachable

set -u

CONFIG=/Library/VirtualMac/network-watchdog.conf
LOG=/var/log/virtualmac-network-watchdog.log

INTERVAL=2
FAILS=2
INTERFACE=""
SAFETY_RENEW=0
MAX_BACKOFF=60
PING_WAIT=200
RENEW_WAIT=1
BOUNCE_WAIT=15
SERVICE_WAIT=15
FRESH_DISCOVER=1

if [ -r "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi

# Network service name, resolved once while the network is healthy. Resolving it
# during a repair is unreliable: networksetup talks to configd, which can return
# nothing useful while the network is being reconfigured. That used to disable
# the last-resort step exactly when it was needed.
SERVICE=""

# Start of the repair in progress, for the step timings written to the log.
REPAIR_START=0

log() {
    printf '%s %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
}

# Whole seconds since the current repair began.
elapsed() {
    printf '%s' "$(( $(/bin/date +%s) - REPAIR_START ))"
}

# Interface carrying the default route, falling back to the first usable en*.
iface() {
    if [ -n "$INTERFACE" ]; then
        printf '%s' "$INTERFACE"
        return
    fi
    i=$(/sbin/route -n get default 2>/dev/null |
        /usr/bin/awk '/interface:/{print $2; exit}')
    if [ -z "${i:-}" ]; then
        for candidate in en0 en1 en2 en3; do
            if /sbin/ifconfig "$candidate" >/dev/null 2>&1; then
                i=$candidate
                break
            fi
        done
    fi
    printf '%s' "${i:-}"
}

# Current default gateway.
gateway() {
    /sbin/route -n get default 2>/dev/null |
        /usr/bin/awk '/gateway:/{print $2; exit}'
}

# IPv4 address of $1, if it currently has one.
address_of() {
    /usr/sbin/ipconfig getifaddr "$1" 2>/dev/null
}

healthy() {
    g=$(gateway)
    [ -n "${g:-}" ] || return 1
    # A probe that gets no answer costs about a second in ARP resolution no
    # matter how long the reply timeout is, so the timeout only adds to it: an
    # unreachable gateway took 1.8s at 800ms but 1.1s at 100ms. A gateway on the
    # local link answers in milliseconds, so keep it short.
    /sbin/ping -c 1 -W "$PING_WAIT" -q "$g" >/dev/null 2>&1
}

# Start a DHCP transaction without waiting for it.
#
# ipconfig blocks until configd finishes or gives up on the exchange, and on a
# network where the exchange cannot succeed that is several seconds of dead
# time. configd performs the transaction itself, so the caller can stop waiting
# without cancelling it.
start_dhcp() {
    /usr/sbin/ipconfig set "$1" DHCP >/dev/null 2>&1 &
    DHCP_PID=$!
}

# Stop waiting for the transaction started by start_dhcp.
#
# ipconfig does not exit promptly on SIGTERM, so a plain kill would leave the
# caller waiting. SIGKILL cannot be ignored. The exit status is not needed here,
# and waiting on a command that may be blocked in the kernel could stall the
# ladder all over again, so the process is killed but not waited for. The shell
# reaps it when it dies.
stop_waiting_for_dhcp() {
    if [ -n "${DHCP_PID:-}" ]; then
        /bin/kill -9 "$DHCP_PID" 2>/dev/null
        DHCP_PID=""
    fi
}

# Wait up to $1 seconds for the gateway to answer again.
wait_for_gateway() {
    wg_remaining=$1
    while [ "$wg_remaining" -gt 0 ]; do
        healthy && return 0
        /bin/sleep 1
        wg_remaining=$((wg_remaining - 1))
    done
    healthy
}

# Name of the network service backed by $1, e.g. "Ethernet". Retries briefly,
# because this is only meaningful while the network is usable.
resolve_service() {
    rs_dev=$1
    [ -n "${rs_dev:-}" ] || return 1
    rs_tries=0
    while [ "$rs_tries" -lt 3 ]; do
        rs_name=$(/usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null |
            /usr/bin/awk -v dev="$rs_dev" '
                /^\([0-9]+\)/ {
                    name = $0
                    sub(/^\([0-9]+\) /, "", name)
                    next
                }
                index($0, "Device: " dev ")") { print name; exit }
            ')
        if [ -n "${rs_name:-}" ]; then
            printf '%s' "$rs_name"
            return 0
        fi
        rs_tries=$((rs_tries + 1))
        /bin/sleep 1
    done
    return 1
}

# Returns 0 as soon as the gateway answers again.
repair() {
    i=$(iface)
    if [ -z "${i:-}" ]; then
        log "repair aborted: no interface found"
        return 1
    fi

    REPAIR_START=$(/bin/date +%s)
    old_address=$(address_of "$i")
    log "  +$(elapsed)s begin (iface=$i address=${old_address:-none})"

    # 1. Drop stale ARP state and force a fresh resolution. This is free, and it
    #    has never been observed to be sufficient on its own, so it is not worth
    #    a probe to confirm: the renew step below checks the result anyway.
    g=$(gateway)
    [ -n "${g:-}" ] && /usr/sbin/arp -d "$g" 2>/dev/null
    /usr/sbin/arp -d -a 2>/dev/null
    log "  +$(elapsed)s arp flushed"

    # 2. Renew the lease: refreshes address, router and DNS configuration.
    start_dhcp "$i"
    log "  +$(elapsed)s renew started"
    wait_for_gateway "$RENEW_WAIT" && {
        log "  +$(elapsed)s renew wait finished (gateway up)"
        stop_waiting_for_dhcp
        log "  +$(elapsed)s renew command released"
        return 0
    }
    stop_waiting_for_dhcp
    log "  +$(elapsed)s renew insufficient"

    # 3. Bounce the interface. After the host moves to a different subnet this
    #    is the step that actually recovers the guest: the old lease belongs to
    #    a network that is gone, so a renew cannot help and the client has to
    #    acquire a new one.
    /sbin/ifconfig "$i" down 2>/dev/null
    /bin/sleep 1
    /sbin/ifconfig "$i" up 2>/dev/null
    if [ "${FRESH_DISCOVER:-0}" -gt 0 ]; then
        /usr/sbin/ipconfig set "$i" NONE 2>/dev/null
    fi
    start_dhcp "$i"
    log "  +$(elapsed)s bounced (address was ${old_address:-none})"

    bounce_left=$BOUNCE_WAIT
    lease_changed=0
    while [ "$bounce_left" -gt 0 ]; do
        current_address=$(address_of "$i")
        if [ "$lease_changed" -eq 0 ] && [ -n "${current_address:-}" ] &&
            [ "$current_address" != "$old_address" ]; then
            lease_changed=1
            log "  +$(elapsed)s lease ${old_address:-none} -> $current_address"
        fi
        healthy && {
            stop_waiting_for_dhcp
            log "  +$(elapsed)s gateway answered (address=${current_address:-none})"
            return 0
        }
        /bin/sleep 1
        bounce_left=$((bounce_left - 1))
    done
    stop_waiting_for_dhcp
    healthy && return 0

    # 4. Last resort: toggle the network service. This is the scripted form of
    #    the "disable the adapter, then enable it" workaround, and it rebuilds
    #    the service's DHCP client state that ifconfig alone may not reset.
    if [ -n "${SERVICE:-}" ]; then
        log "escalating: toggling network service '$SERVICE'"
        /usr/sbin/networksetup -setnetworkserviceenabled "$SERVICE" off 2>/dev/null
        /bin/sleep 2
        /usr/sbin/networksetup -setnetworkserviceenabled "$SERVICE" on 2>/dev/null
        start_dhcp "$i"
        wait_for_gateway "$SERVICE_WAIT" && {
            stop_waiting_for_dhcp
            log "  +$(elapsed)s gateway answered after the service toggle"
            return 0
        }
        stop_waiting_for_dhcp
        return 1
    fi
    log "escalating: no network service name cached; cannot toggle it"
    return 1
}

boot_iface=$(iface)
boot_gateway=$(gateway)
if [ -n "$boot_iface" ]; then
    SERVICE=$(resolve_service "$boot_iface")
fi
log "watchdog started (interval=${INTERVAL}s fails=${FAILS} iface=${boot_iface} gateway=${boot_gateway} service=${SERVICE} fresh=${FRESH_DISCOVER})"

failures=0
backoff=0
last_repair=0
last_safety=$(/bin/date +%s)

while :; do
    if healthy; then
        if [ "$failures" -ge "$FAILS" ]; then
            log "gateway reachable again"
        fi
        # If the watchdog started while the network was already broken there was
        # no healthy moment to resolve the service name; take one now.
        if [ -z "${SERVICE:-}" ]; then
            i=$(iface)
            if [ -n "${i:-}" ]; then
                resolved=$(resolve_service "$i")
                if [ -n "${resolved:-}" ]; then
                    SERVICE=$resolved
                    log "resolved network service '$SERVICE'"
                fi
            fi
        fi
        failures=0
        backoff=0
    else
        failures=$((failures + 1))
        if [ "$failures" -ge "$FAILS" ]; then
            now=$(/bin/date +%s)
            # Never repair more often than every 15s, and back off when the
            # repair keeps failing (e.g. a gateway that filters ICMP).
            if [ $((now - last_repair)) -ge 15 ]; then
                last_repair=$now
                log "gateway unreachable (${failures} checks); repairing iface=$(iface)"
                if repair; then
                    log "repair succeeded"
                    failures=0
                    backoff=0
                else
                    backoff=$((backoff + INTERVAL))
                    [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
                    log "repair failed; next attempt in ~$((INTERVAL + backoff))s"
                fi
            fi
        fi
    fi

    # Optional safety net: an unconditional periodic renew, useful if the
    # gateway stops answering ICMP but the link state is still stale.
    if [ "${SAFETY_RENEW:-0}" -gt 0 ]; then
        now=$(/bin/date +%s)
        if [ $((now - last_safety)) -ge "$SAFETY_RENEW" ]; then
            last_safety=$now
            i=$(iface)
            if [ -n "${i:-}" ]; then
                # Give the request time to reach configd before giving up on
                # the command; the transaction itself outlives it.
                start_dhcp "$i"
                /bin/sleep 1
                stop_waiting_for_dhcp
            fi
        fi
    fi

    # Probe faster once something has failed: a real outage is then confirmed in
    # about a second per probe instead of a whole interval.
    if [ "$failures" -gt 0 ]; then
        /bin/sleep 1
    else
        /bin/sleep $((INTERVAL + backoff))
    fi
done
