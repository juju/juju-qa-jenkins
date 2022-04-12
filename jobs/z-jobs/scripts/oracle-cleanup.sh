#!/bin/bash

## oracle-cleanup.sh
##
## Perform some cleanup of the Oracle Public Cloud platform
## Access credentials will be parsed from $JUJU_DATA/credentials.yaml
## or loaded from environment variables.

AGE=12  # age of instances (hours) to be deleted

# load our access credentials
CREDENTIALS=
for file in $JUJU_DATA/credentials.yaml \
       $JUJU_DATA/credentials.yaml; do
    if [ -f "$file" ]; then
        CREDENTIALS=$file
        break
    fi
done

parse_yaml() {
    local s='[[:space:]]*' w='[-a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
    sed -ne "s|^\($s\):|\1|" \
         -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
         -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
        awk -F$fs '{
            indent = length($1)/2;
            vname[indent] = $2;
            for (i in vname) {if (i > indent) {delete vname[i]}}
            if (length($3) > 0) {
                vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
                printf("%s%s='"'"'%s'"'"'\n", vn, $2, $3);
            }
        }' |
        sed ':b; s/^\([^=]*\)-/\1/; tb'
}

eval $(parse_yaml $CREDENTIALS | grep 'oracle')
test -z "$ORACLE_USER" &&
    ORACLE_USER=$credentials_oracle_credentials_username
test -z "$ORACLE_PASSWORD" &&
    ORACLE_PASSWORD=$credentials_oracle_credentials_password
test -z "$ORACLE_COMPUTE" &&
    ORACLE_COMPUTE="Compute-$credentials_oracle_credentials_identitydomain"
test -z "$ORACLE_URL" &&
    ORACLE_URL="https://compute.uscom-central-1.oraclecloud.com/"

if [ -z "$ORACLE_URL" -o \
     -z "$ORACLE_USER" -o \
     -z "$ORACLE_PASSWORD" -o \
     -z "$ORACLE_COMPUTE" ]; then
    echo "ERROR: Environment variables not set. Variables need to be set"
    echo "in the environment or loaded from a juju style credentials file"
    echo "ORACLE_URL"
    echo "ORACLE_USER"
    echo "ORACLE_PASSWORD"
    echo "ORACLE_COMPUTE"
    exit 1
fi

# Get cookie
export oracle_cookie=$(curl -s -i -X POST \
    -H "Content-Type: application/oracle-compute-v3+json" \
    -d '{"user":"/'$ORACLE_COMPUTE/$ORACLE_USER'","password":"'$ORACLE_PASSWORD'"}' \
    $ORACLE_URL/authenticate/ | grep Set-Cookie | sed 's/Set-Cookie: //' )

echo "Setting cookie to $oracle_cookie"

deletethings() {
    # optional first argument of -d for dry-run (no-op)
    dryrun=false
    if [ "$1" == "-d" ]; then
        dryrun=true
        shift
    fi
    # first param: string in url of api call
    apiname=${1?ERROR: deletethings requires at least 1 parameter}
    # optional second param: english version of apiname
    englishname=${2=$apiname}
    #

    # Note we only match juju* things
    things=$(curl -s -X GET -H "Cookie: $oracle_cookie" \
        -H "Content-Type: application/oracle-compute-v3+json" \
        -H "Accept: application/oracle-compute-v3+json" \
        $ORACLE_URL/$apiname/$ORACLE_COMPUTE/$ORACLE_USER/ |
        jq '.[][] | .name' |
        sed -e 's/[",]//g' -e "s!/$ORACLE_COMPUTE/$ORACLE_USER/!!" |
        grep juju)

    num=$(echo "$things" | wc -w)
    if [ "$num" -eq 0 ]; then
        echo ":: No 'juju' $englishname to remove."
    else
        is=are
        test "$num" -eq 1 &&
            is=is englishname=$(echo $englishname | sed 's/s$//')
        if $dryrun; then
            echo ":: There $is $num $englishname. Not removing."
        else
            echo ":: Removing $num $englishname:"
        fi

        # Delete things one at a time
        for thing in $things; do
            echo $thing
            $dryrun && continue
            output=$(curl -s -i -X DELETE -H "Cookie: $oracle_cookie" \
                "$ORACLE_URL/$apiname/$ORACLE_COMPUTE/$ORACLE_USER/$thing")

            if ! echo "$output" | grep -q "^HTTP/[^ ]* 204"; then
                echo "$output"
            fi
        done
    fi
}

deleteinstances() {
    now=$(date +%s)
    ago=$((now - AGE*60*60))
    englishname=Instances
    # Get all "juju" instances older than AGE hours
    instances=$(curl -s -X GET -H "Cookie: $oracle_cookie" \
        "$ORACLE_URL/instance/$ORACLE_COMPUTE/$ORACLE_USER/" |
        jq -c ".[][]
            | select(.start_time | fromdateiso8601 < $ago)
            | [.name, .state]" |
        sed -e 's/[]["]//g' -e "s!/$ORACLE_COMPUTE/$ORACLE_USER/!!" |
        grep juju)

    num=$(echo "$instances" | wc -w)
    if [ "$num" -eq 0 ]; then
        echo ":: No 'juju' $englishname older than $AGE hours."
    else
        test "$num" -eq 1 &&
            englishname=$(echo $englishname | sed 's/s$//')
        echo ":: Removing $num $englishname:"
        for instance_state in $instances; do
            instance=(${instance_state//,/ })
            echo ${instance[0]} :: ${instance[1]}
            # skip instances that are already stopping
            test "${instance[1]}" == "stopping" && continue
            output=$(curl -s -i -X DELETE -H "Cookie: $oracle_cookie" \
                "$ORACLE_URL/instance/$ORACLE_COMPUTE/$ORACLE_USER/${instance[0]}")
            if ! echo "$output" | grep -q "^HTTP[^ ]* 204"; then
                echo "$output"
            fi
        done
    fi
}

# Remove all old instances
deleteinstances
# Remove all security rules
deletethings "network/v1/secrule" "Security Rules"
# Remove all security protocols
deletethings "network/v1/secprotocol" "Security Protocols"
# Remove all Access Control Lists
deletethings "network/v1/acl" "ACLs"
# Remove all security rules (v2)
deletethings "secrule" "(v2) Security Rules"
# Remove all seclists
deletethings "seclist" "Security Lists"
# Remove all security application (v2)
deletethings "secapplication" "(v2) Security Applications"
# Should we Remove all IP reservations
deletethings -d "ip/reservation" "IP Reservations"
# Should we Remove all IP networks
deletethings -d "network/v1/ipnetwork" "IP Networks"
# Should we Remove all IP networks exchanges
deletethings -d "network/v1/ipnetworkexchange" "IP Network Exchanges"
# Should we Remove all storage volumes
deletethings -d "storage/volume" "Storage Volumes"
