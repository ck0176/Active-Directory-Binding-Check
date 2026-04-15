#!/bin/bash

##############################################################
# Utility - AD Binding Status & Repair
# SwiftDialog-based tool that checks AD binding health,
# displays status in a list-item dialog, and optionally
# triggers a rebind via Jamf policy, then re-checks.
#
# Combines:
#   - Tech Helper (look/feel, AD OU + trust logic, infobox)
#   - Check AD Bind And Report To User (bind/object checks)
#   - Bind My Mac trigger (rebind path)
#
# Jamf Parameters:
#   $4 - (optional) AD admin username if using inline rebind
#   $5 - (optional) AD admin password if using inline rebind
##############################################################

##############################################################
# Global Config
##############################################################

DIALOG="/usr/local/bin/dialog"
BANNER="/Library/NIDDK/SuperFriends/NIDDKBanner.png"
ICON="/Library/NIDDK/SuperFriends/NIDDKGreenLogo.png"
TITLE="NIDDK AD Binding Status"
BANNER_TITLE="Active Directory Binding"
TMP_JSON="/tmp/niddk_ad_binding_dialog.json"
WAIT_CMDFILE="/tmp/niddk_rebind_cmdfile"

# Jamf trigger name for your existing Bind My Mac policy
REBIND_TRIGGER="ADBinding"

# Jamf parameters (ready to go incase my binding trigger policy flakes out and doesn't work with this script)
AAUSERNAME="$4"
AAPASSWORD="$5"


##############################################################
# SwiftDialog Install Check
##############################################################

DialogInstall() {
    pkgfile="SwiftDialog.pkg"
    logfile="/Library/Logs/SwiftDialogInstallScript.log"
    URL="https://github.com$(curl -sfL "$(curl -sfL "https://github.com/bartreardon/swiftDialog/releases/latest" | tr '"' "\n" | grep -i "expanded_assets" | head -1)" | tr '"' "\n" | grep -i "^/.*\/releases\/download\/.*\.pkg" | head -1)"

    echo "--" >> "${logfile}"
    echo "$(date): Downloading latest SwiftDialog." >> "${logfile}"
    curl -s -L -J -o /tmp/${pkgfile} ${URL}
    echo "$(date): Installing SwiftDialog..." >> "${logfile}"
    cd /tmp
    sudo installer -pkg ${pkgfile} -target /
    sleep 5
    echo "$(date): Cleaning up installer." >> "${logfile}"
    rm /tmp/"${pkgfile}"
}

if ! command -v dialog &>/dev/null; then
    echo "SwiftDialog not found — installing..."
    DialogInstall
fi


##############################################################
# Device Icon
##############################################################

get_device_icon() {
    local model
    model=$(ioreg -l | awk '/product-name/ { split($0, line, "\""); printf("%s\n", line[4]); }')

    if [[ "$model" == *"Book"* ]]; then
        DEVICE_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/com.apple.macbookpro-14-2021-silver.icns"
    elif [[ "$model" == *"mini"* ]]; then
        DEVICE_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/com.apple.macmini-2020.icns"
    elif [[ "$model" == *"iMac"* ]]; then
        DEVICE_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/com.apple.imac-unibody-27.icns"
    else
        DEVICE_ICON="$ICON"
    fi
}


##############################################################
# Static System Info — gathered once for infobox
# Hardware doesn't change between loop iterations so no
# need to re-run system_profiler on every rebind cycle.
##############################################################

gather_static_info() {
    local model
    model=$(ioreg -l | awk '/product-name/ { split($0, line, "\""); printf("%s\n", line[4]); }')

    COMP_NAME_STATIC=$(scutil --get ComputerName 2>/dev/null || hostname)
    SERIAL=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number/ {print $2; exit}')
    CHIP=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip|Processor Name/ {print $2; exit}')
    RAM=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Memory/ {print $2; exit}' | xargs)
    FREE_DISK=$(df -H / | awk 'NR==2 {print $4 " free of " $2}')
    uptime="$(get_uptime)"

    OS_NAME=$(awk '/SOFTWARE LICENSE AGREEMENT FOR macOS/{
        sub(/^.*macOS[[:space:]]+/, "", $0)
        sub(/\\$/, "", $0)
        sub(/[[:space:]][0-9]+(\.[0-9]+)*$/, "", $0)
        print; exit
    }' "/System/Library/CoreServices/Setup Assistant.app/Contents/Resources/en.lproj/OSXSoftwareLicense.rtf" 2>/dev/null)
    OS_VER=$(sw_vers -productVersion 2>/dev/null)
    OS_DISPLAY="${OS_NAME} ${OS_VER}"

    SD_INFOBOX="Name:**${COMP_NAME_STATIC}**\nModel:**${model}**\nSerial:**${SERIAL}**\nmacOS:**${OS_DISPLAY}**\nProcessor:**${CHIP}**\nMemory:**${RAM}**\nDisk:**${FREE_DISK}**\nUptime:**${uptime}**"
}

get_uptime() {
    local boot now diff d h m

    boot=$(sysctl -n kern.boottime | awk '{print $4}' | tr -d ',')
    now=$(date +%s)
    diff=$((now - boot))

    d=$((diff/86400))
    h=$(( (diff%86400)/3600 ))
    m=$(( (diff%3600)/60 ))

    if (( d > 0 )); then
        printf "%dd %dh %dm\n" "$d" "$h" "$m"
    elif (( h > 0 )); then
        printf "%dh %dm\n" "$h" "$m"
    else
        printf "%dm\n" "$m"
    fi
}

##############################################################
# AD Information Gathering
##############################################################

gather_ad_info() {

    # --- Bound to AD? ---
    AD_IS_BOUND="No"
    if [[ "$(/usr/bin/dscl localhost -list /Active\ Directory 2>/dev/null)" == "NIH" ]] && \
       [[ $(/usr/bin/dscl /Active\ Directory/NIH/nih.gov -read /Users 2>/dev/null | /usr/bin/grep -c "not valid") -eq 0 ]]; then
        AD_IS_BOUND="Yes"
    fi

    # --- Computer account name ---
    COMP_ACCOUNT=$(/usr/sbin/dsconfigad -show 2>/dev/null | \
        /usr/bin/grep "Computer Account" | \
        /usr/bin/awk -F "=" '{print $2}' | \
        /usr/bin/xargs 2>/dev/null)
    [[ -z "$COMP_ACCOUNT" ]] && COMP_ACCOUNT="N/A"

    # --- AD object exists? ---
    AD_OBJECT_EXISTS="No"
    if [[ "$COMP_ACCOUNT" != "N/A" ]]; then
        if [[ -z $(/usr/bin/dscl /Active\ Directory/NIH/nih.gov \
                       -read /Computers/"$COMP_ACCOUNT" 2>&1 | \
                       /usr/bin/grep "eDSRecordNotFound") ]]; then
            AD_OBJECT_EXISTS="Yes"
        fi
    fi

    # --- AD Trust and OU ---
    AD_TRUST_STATUS="Not Bound"
    AD_OU="N/A"
    AD_DOMAIN="N/A"

    ADdomainPath=$(dscl /Search -read / CSPSearchPath 2>/dev/null | \
        grep "Active Directory" | head -1 | xargs 2>/dev/null)

    if [[ -n "$ADdomainPath" ]]; then
        if dscl "$ADdomainPath" -read /Users &>/dev/null; then
            AD_TRUST_STATUS="Trust Valid"
        else
            AD_TRUST_STATUS="Trust Broken"
        fi

        AD_DOMAIN=$(dsconfigad -show 2>/dev/null | awk '/Active Directory Domain/{print $NF}')
        [[ -z "$AD_DOMAIN" ]] && AD_DOMAIN="N/A"

        if [[ "$COMP_ACCOUNT" != "N/A" ]]; then
            dn=$(dscl /Search read /Computers/"$COMP_ACCOUNT" \
                dsAttrTypeNative:distinguishedName 2>/dev/null | \
                sed -n 's/^ *dsAttrTypeNative:distinguishedName: *//p')
            if [[ -n "$dn" ]]; then
                AD_OU=$(echo "$dn" | sed 's/^CN=[^,]*,//; s/,DC=/./g; s/^OU=//; s/,OU=/\//g')
            fi
        fi
    fi

    # --- Overall Bound Correctly? ---
    if [[ "$AD_IS_BOUND" == "Yes" ]] && [[ "$AD_OBJECT_EXISTS" == "Yes" ]]; then
        BOUND_CORRECTLY="Yes"
        BOUND_STATUS_TEXT="Machine is Bound Correctly"
        BOUND_ICON="SF=checkmark.seal.fill,color=green,weight=bold,bgcolor=bgnone"
    else
        BOUND_CORRECTLY="No"
        BOUND_STATUS_TEXT="Machine is NOT Bound Correctly"
        BOUND_ICON="SF=xmark.seal.fill,color=red,weight=bold,bgcolor=bgnone"
    fi

    # --- Per-row icons ---
    if [[ "$AD_TRUST_STATUS" == "Trust Valid" ]]; then
        TRUST_ICON="SF=checkmark.circle.fill,color=green,weight=bold,bgcolor=bgnone"
    elif [[ "$AD_TRUST_STATUS" == "Trust Broken" ]]; then
        TRUST_ICON="SF=xmark.circle.fill,color=red,weight=bold,bgcolor=bgnone"
    else
        TRUST_ICON="SF=questionmark.circle,color=gray,weight=bold,bgcolor=bgnone"
    fi

    if [[ "$AD_OBJECT_EXISTS" == "Yes" ]]; then
        OBJECT_ICON="SF=checkmark.circle.fill,color=green,weight=bold,bgcolor=bgnone"
        OBJECT_STATUS_TEXT="AD Object Found"
    else
        OBJECT_ICON="SF=xmark.circle.fill,color=red,weight=bold,bgcolor=bgnone"
        OBJECT_STATUS_TEXT="AD Object NOT Found"
    fi

    if [[ "$AD_IS_BOUND" == "Yes" ]]; then
        BOUND_FIELD_ICON="SF=checkmark.circle.fill,color=green,weight=bold,bgcolor=bgnone"
        BOUND_FIELD_TEXT="Bound"
    else
        BOUND_FIELD_ICON="SF=xmark.circle.fill,color=red,weight=bold,bgcolor=bgnone"
        BOUND_FIELD_TEXT="Not Bound"
    fi
}


##############################################################
# Build and Show Dialog
##############################################################

show_dialog() {

    # NOTE from Bart to me! : No trailing comma on the last list item — SwiftDialog is sometimes
    # lenient but malformed JSON will silently drop items or break the list.
    cat << EOF > "$TMP_JSON"
{
    "listitem" : [
        {"title" : "Computer Account:", "icon" : "SF=desktopcomputer,color=blue,bgcolor=bgnone,weight=bold",   "statustext" : "$COMP_ACCOUNT"},
        {"title" : "AD Domain:",        "icon" : "SF=globe,color=blue,bgcolor=bgnone,weight=bold",             "statustext" : "$AD_DOMAIN"},
        {"title" : "AD OU:",            "icon" : "SF=person.2.circle,color=orange,bgcolor=bgnone,weight=bold", "statustext" : "$AD_OU"},
        {"title" : "AD Bind Status:",   "icon" : "$BOUND_FIELD_ICON",                                          "statustext" : "$BOUND_FIELD_TEXT"},
        {"title" : "AD Trust:",         "icon" : "$TRUST_ICON",                                                "statustext" : "$AD_TRUST_STATUS"},
        {"title" : "AD Object:",        "icon" : "$OBJECT_ICON",                                               "statustext" : "$OBJECT_STATUS_TEXT"},
        {"title" : "Overall Status:",   "icon" : "$BOUND_ICON",                                                "statustext" : "$BOUND_STATUS_TEXT"}
    ]
}
EOF

    local DIALOG_ARGS=(
        --bannerimage "$BANNER"
        --bannertitle "$BANNER_TITLE"
        --titlefont 'shadow=1'
        --message none
        --icon "$DEVICE_ICON"
        --jsonfile "$TMP_JSON"
        --infobox "$SD_INFOBOX"
        --height 560
        --width 830
        --moveable
        --buttonstyle "center"
    )

    if [[ "$BOUND_CORRECTLY" == "Yes" ]]; then
        "$DIALOG" "${DIALOG_ARGS[@]}" \
            --button1text "OK"
        DIALOG_EXIT=$?
    else
        "$DIALOG" "${DIALOG_ARGS[@]}" \
            --button1text "Dismiss" \
            --button2text "Rebind Now"
        DIALOG_EXIT=$?
    fi
}


##############################################################
# Rebind — via Jamf Policy Trigger
##############################################################
# Uses --commandfile for reliable programmatic dismiss.
# Writing "quit:" to the command file is the correct way to
# close a running SwiftDialog instance. kill alone is not
# reliable because SwiftDialog may spawn child processes that
# outlive the parent PID we captured with $!
##############################################################

do_rebind() {

    rm -f "$WAIT_CMDFILE"
    touch "$WAIT_CMDFILE"

    "$DIALOG" \
        --bannerimage "$BANNER" \
        --bannertitle "Attempting to Rebind..." \
        --message "Please wait — this may take up to 60 seconds." \
        --icon "SF=globe.badge.chevron.backward,color=orange,weight=bold,animation=pulse" \
        --progress \
        --progresstext "Connecting to NIH domain..." \
        --height 310 \
        --width 650 \
        --moveable \
    --mini \
        --button1disabled \
        --button1text "Please wait..." \
        --commandfile "$WAIT_CMDFILE" &
    WAIT_DIALOG_PID=$!

    # ── Option A: Jamf Policy Trigger (recommended) ──────────────────────────
    /usr/local/bin/jamf policy -trigger "$REBIND_TRIGGER"
    REBIND_RESULT=$?
    # ─────────────────────────────────────────────────────────────────────────

    # ── Option B: Inline dsconfigad (requires $4/$5 creds from Jamf) ─────────
    # Uncomment below and comment out Option A.
    # Ensure $4/$5 are populated with AD admin creds in your Jamf policy.
    #
    # AD_NAME="${COMP_NAME_STATIC:0:15}"
    # dsconfigad -force -remove -u "$AAUSERNAME" -p "$AAPASSWORD" 2>/dev/null
    # dsconfigad -f -a "$AD_NAME" -domain nih.gov -u "$AAUSERNAME" -p "$AAPASSWORD" \
    #     -ou "OU=Mac,OU=Computers,OU=NIDDK,OU=NIH,OU=AD,DC=nih,DC=gov"
    # dsconfigad -alldomains enable -localhome enable -protocol smb -mobile enable \
    #     -mobileconfirm disable -useuncpath disable \
    #     -groups 'niddk domain admins,niddk_helpdesk_aa,NIDDKISSOSecondary'
    # dsconfigad -packetencrypt require
    # dsconfigad -packetsign require
    # REBIND_RESULT=$?
    # ─────────────────────────────────────────────────────────────────────────

    # Dismiss via command file — the reliable method
    echo "quit:" >> "$WAIT_CMDFILE"
    sleep 1

    # Belt and suspenders: kill if still alive
    kill "$WAIT_DIALOG_PID" 2>/dev/null
    wait "$WAIT_DIALOG_PID" 2>/dev/null
    rm -f "$WAIT_CMDFILE"

    # Brief pause to let AD settle before re-checking
    sleep 3

    return $REBIND_RESULT
}


##############################################################
# Main Loop
##############################################################

get_device_icon
gather_static_info   # hardware info — called once, not on every loop

while true; do

    gather_ad_info
    show_dialog

    case $DIALOG_EXIT in
        0)
            echo "User dismissed dialog."
            break
            ;;
        2)
            echo "User requested rebind — triggering policy: $REBIND_TRIGGER"
            do_rebind
            # Loop continues — re-gather and re-display updated status
            ;;
        *)
            echo "Dialog exited with code $DIALOG_EXIT — exiting."
            break
            ;;
    esac

done


##############################################################
# Cleanup
##############################################################

rm -f "$TMP_JSON"
rm -f "$WAIT_CMDFILE"
exit 0